{-#LANGUAGE DeriveGeneric #-}
module Handler.Instructor where

import Import
import Util.Data
import Util.Database
import Control.Monad (fail)
import Yesod.Form.Bootstrap3
import Carnap.GHCJS.SharedTypes(ProblemSource(..))
import Yesod.Form.Jquery
import Handler.User (scoreByIdAndClassTotal, scoreByIdAndClassPerProblem)
import Text.Blaze.Html (toMarkup)
import Text.Read (readMaybe)
import Data.Time
import Data.Time.Zones
import Data.Time.Zones.DB
import Data.Time.Zones.All
import Data.Aeson (decode,encode)
import qualified Data.IntMap (keys, insert,fromList,toList,delete)
import qualified Data.Text as T
import qualified Data.List as L
import System.FilePath
import System.Directory (getDirectoryContents,removeFile, doesFileExist, createDirectoryIfMissing)

putInstructorR :: Text -> Handler Value
putInstructorR ident = do
        ((assignmentrslt,_),_) <- runFormPost (identifyForm "updateAssignment" $ updateAssignmentForm)
        ((courserslt,_),_)     <- runFormPost (identifyForm "updateCourse" $ updateCourseForm)
        ((documentrslt,_),_)   <- runFormPost (identifyForm "updateDocument" $ updateDocumentForm)
        case (assignmentrslt,courserslt,documentrslt) of
            (FormSuccess (idstring, mdue, mduetime,mfrom,mfromtime,muntil,muntiltime, mdesc),_,_) -> do
                 case readMaybe idstring of
                      Nothing -> returnJson ("Could not read assignment key"::Text)
                      Just k -> do
                        mval <- runDB (get k)
                        case mval of
                          Nothing -> returnJson ("Could not find assignment!"::Text)
                          Just v ->
                            do let cid = assignmentMetadataCourse v
                               runDB $ do course <- get cid >>= maybe (liftIO $ fail "could not get course") pure
                                          let (Just tz) = tzByName . courseTimeZone $ course
                                          let mtimeUpdate Nothing Nothing field = update k [ field =. Nothing ]
                                              mtimeUpdate mdate mtime field = maybeDo mdate (\date->
                                                 do let localtime = case mtime of
                                                            (Just time) -> LocalTime date time
                                                            _ -> LocalTime date (TimeOfDay 23 59 59)
                                                    update k [ field =. (Just $ localTimeToUTCTZ tz localtime) ])
                                          mtimeUpdate mdue mduetime AssignmentMetadataDuedate
                                          mtimeUpdate mfrom mfromtime AssignmentMetadataVisibleFrom
                                          mtimeUpdate muntil muntiltime AssignmentMetadataVisibleTill
                                          update k [ AssignmentMetadataDescription =. (unTextarea <$> mdesc) ]
                               returnJson ("updated!"::Text)
            (_,FormSuccess (idstring,mdesc,mstart,mend,mpoints),_) -> do
                             case readMaybe idstring of
                                 Just k -> do runDB $ do update k [ CourseDescription =. (unTextarea <$> mdesc) ]
                                                         maybeDo mstart (\start -> update k
                                                           [ CourseStartDate =. UTCTime start 0 ])
                                                         maybeDo mend (\end-> update k
                                                           [ CourseEndDate =. UTCTime end 0 ])
                                                         maybeDo mpoints (\points-> update k [ CourseTotalPoints =. points ])
                                              returnJson ("updated!"::Text)
                                 Nothing -> returnJson ("could not find course!"::Text)
            (_,_,FormSuccess (idstring, mscope, mdesc,mfile,mtags)) -> do
                             case readMaybe idstring of
                                 Just k -> do
                                    mdoc <- runDB (get k)
                                    case mdoc of
                                        Nothing -> returnJson ("could not find document!"::Text)
                                        Just doc -> do
                                           maybeIdent <- getIdent $ documentCreator doc
                                           --XXX: shouldn't be possible for a document to exist without a creator
                                           case maybeIdent of
                                             Just ident -> do
                                                 runDB $ do update k [ DocumentDescription =. (unTextarea <$> mdesc) ]
                                                            maybeDo mscope (\scope -> update k [ DocumentScope =. scope ])
                                                            maybeDo mtags (\tags -> do
                                                                              oldTags <- selectList [TagBearer ==. k] []
                                                                              mapM (delete . entityKey) oldTags
                                                                              forM tags (\tag -> insert $ Tag k tag)
                                                                              return ())
                                                 maybeDo mfile (saveTo ("documents" </> unpack ident) (unpack $ documentFilename doc))
                                                 returnJson ("updated!"::Text)
                                             Nothing -> returnJson ("document did not have a creator. This is a bug."::Text)
                                 Nothing -> returnJson ("could not read document key"::Text)

            (FormMissing,FormMissing,FormMissing) -> returnJson ("no form" :: Text)
            (form1,form2,form3) -> returnJson ("errors: " <> errorsOf form1 <> errorsOf form2 <> errorsOf form3)
                where errorsOf (FormFailure s) = concat s <> ", "
                      errorsOf _ = ""

deleteInstructorR :: Text -> Handler Value
deleteInstructorR ident = do
    msg <- requireJsonBody :: Handler InstructorDelete
    case msg of
      DeleteAssignment id ->
        do datadir <- appDataRoot <$> (appSettings <$> getYesod)
           deleted <- runDB $ deleteCascade id
           returnJson ("Assignment deleted" :: Text)
      DeleteProblems coursename setnum ->
        do checkCourseOwnership coursename
           mclass <- runDB $ getBy $ UniqueCourse coursename
           case mclass of
                Just (Entity classkey theclass)->
                    do case readAssignmentTable <$> courseTextbookProblems theclass  of
                           Just assign -> do runDB $ update classkey
                                                            [CourseTextbookProblems =. (Just $ BookAssignmentTable $ Data.IntMap.delete setnum assign)]
                                             returnJson ("Deleted Assignment"::Text)
                           Nothing -> returnJson ("Assignment table Missing, can't delete."::Text)
                Nothing -> returnJson ("Something went wrong with retriving the course."::Text)
      DeleteCourse coursename ->
        do checkCourseOwnership coursename
           mclass <- runDB $ getBy $ UniqueCourse coursename
           case mclass of
                Just (Entity classkey theclass)->
                    do runDB $ do studentsOf <- selectList [UserDataEnrolledIn ==. Just classkey] []
                                  mapM (\s -> update (entityKey s) [UserDataEnrolledIn =. Nothing]) studentsOf
                                  deleteCascade classkey
                       returnJson ("Class Deleted"::Text)
                Nothing -> returnJson ("No class to delete, for some reason"::Text)
      DeleteDocument fn ->
        do datadir <- appDataRoot <$> (appSettings <$> getYesod)
           musr <- runDB $ getBy $ UniqueUser ident
           case musr of
               Nothing -> returnJson ("Could not get user id."::Text)
               Just usr -> do
                   deleted <- runDB $ do mk <- getBy $ UniqueDocument fn (entityKey usr)
                                         case mk of
                                             Just (Entity k v) ->
                                                do deleteCascade k
                                                   liftIO $ do fe <- doesFileExist (datadir </> "documents" </> unpack ident </> unpack fn)
                                                               if fe then removeFile (datadir </> "documents" </> unpack ident </> unpack fn)
                                                                     else return ()
                                                   return True
                                             Nothing -> return False
                   if deleted
                       then returnJson (fn ++ " deleted")
                       else returnJson ("unable to retrieve metadata for " ++ fn)
      DropStudent sident ->
        do sid <- fromIdent sident
           dropped <- runDB $ do msd <- getBy (UniqueUserData sid)
                                 case msd of
                                     Nothing -> return False
                                     Just (Entity k _) ->
                                        do update k [UserDataEnrolledIn =. Nothing]
                                           return True
           if dropped then returnJson (sident ++ " dropped")
                      else returnJson ("couldn't drop " ++ sident)
      DeleteCoInstructor ciid -> do
          runDB (deleteCascade ciid) >> returnJson ("Deleted" :: Text)

postInstructorR :: Text -> Handler Html
postInstructorR ident = do
    time <- liftIO getCurrentTime
    classes <- classesByInstructorIdent ident
    let activeClasses = filter (\c -> courseEndDate (entityVal c) > time) classes
    docs <- documentsByInstructorIdent ident
    instructors <- runDB $ selectList [UserDataInstructorId !=. Nothing] []
    ((assignmentrslt,_),_) <- runFormPost (identifyForm "uploadAssignment" $ uploadAssignmentForm activeClasses docs)
    ((documentrslt,_),_)   <- runFormPost (identifyForm "uploadDocument" $ uploadDocumentForm)
    ((newclassrslt,_),_)   <- runFormPost (identifyForm "createCourse" createCourseForm)
    ((frombookrslt,_),_)   <- runFormPost (identifyForm "setBookAssignment" $ setBookAssignmentForm activeClasses)
    ((instructorrslt,_),_) <- runFormPost (identifyForm "addCoinstructor" $ addCoInstructorForm instructors ("" :: String))
    case assignmentrslt of
        FormSuccess (doc, Entity classkey theclass, mdue,mduetime,mfrom,mfromtime,mtill,mtilltime, massignmentdesc, mpass, mhidden,mlimit, subtime) ->
            do Entity uid user <- requireAuth
               iid <- instructorIdByIdent (userIdent user)
                        >>= maybe (setMessage "failed to retrieve instructor" >> notFound) pure
               mciid <- if courseInstructor theclass == iid
                            then return Nothing
                            else runDB $ getBy (UniqueCoInstructor iid classkey)
               let (Just tz) = tzByName . courseTimeZone $ theclass
                   localize (mdate,mtime) = case (mdate,mtime) of
                              (Just date, Just time) -> Just $ LocalTime date time
                              (Just date,_)  -> Just $ LocalTime date (TimeOfDay 23 59 59)
                              _ -> Nothing
                   localdue = localize (mdue,mduetime)
                   localfrom = localize (mfrom,mfromtime)
                   localtill = localize (mtill,mtilltime)
                   info = unTextarea <$> massignmentdesc
                   theassigner = mciid
                   thename = documentFilename (entityVal doc)
               asgned <- runDB $ selectList [AssignmentMetadataCourse ==. classkey] []
               dupes <- runDB $ filter (\x -> documentFilename (entityVal x) == thename)
                                <$> selectList [DocumentId <-. map (assignmentMetadataDocument . entityVal) asgned] []
               case mpass of
                   _ | not (null dupes) -> setMessage "Names for assignments must be unique within a course, and it looks like you already have an assignment with this name"
                   Nothing | mhidden == Just True || mlimit /= Nothing -> setMessage "Hidden and time-limited assignments must be password protected"
                   _ -> do success <- tryInsert $ AssignmentMetadata
                                                { assignmentMetadataDocument = entityKey doc
                                                , assignmentMetadataDescription = info
                                                , assignmentMetadataAssigner = entityKey <$> theassigner
                                                , assignmentMetadataDuedate = localTimeToUTCTZ tz <$> localdue
                                                , assignmentMetadataVisibleFrom = localTimeToUTCTZ tz <$> localfrom
                                                , assignmentMetadataVisibleTill = localTimeToUTCTZ tz <$> localtill
                                                , assignmentMetadataDate = subtime
                                                , assignmentMetadataCourse = classkey
                                                , assignmentMetadataAvailability =
                                                    case (mpass,mhidden,mlimit) of
                                                            (Nothing,_,_) -> Nothing
                                                            (Just txt, Just True, Nothing) -> Just (HiddenViaPassword txt)
                                                            (Just txt, Just True, Just min) -> Just (HiddenViaPasswordExpiring txt min)
                                                            (Just txt, _, Just min) -> Just (ViaPasswordExpiring txt min)
                                                            (Just txt, _, _) -> Just (ViaPassword txt)
                                                }
                           case success of Just _ -> return ()
                                           Nothing -> setMessage "This file has already been assigned for this course"
        FormFailure s -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
        FormMissing -> return ()
    case documentrslt of
        FormSuccess (file, sharescope, docdesc, subtime, mtags) ->
            do musr <- runDB $ getBy $ UniqueUser ident
               let fn = fileName file
                   info = unTextarea <$> docdesc
                   Just uid = musr -- FIXME: catch Nothing here
               success <- tryInsert $ Document
                                        { documentFilename = fn
                                        , documentDate = subtime
                                        , documentCreator = entityKey uid
                                        , documentDescription = info
                                        , documentScope = sharescope
                                        }
               case success of
                    Just k -> do saveTo ("documents" </> unpack ident) (unpack fn) file
                                 runDB $ maybeDo mtags (\tags -> do
                                            forM tags (\tag -> insert $ Tag k tag)
                                            return ())
                    Nothing -> setMessage "You already have a shared document with this name."
        FormFailure s -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
        FormMissing -> return ()
    case newclassrslt of
        FormSuccess (title, coursedesc, startdate, enddate, tzlabel) -> do
            miid <- instructorIdByIdent ident
            case miid of
                Just iid ->
                    do let localize x = localTimeToUTCTZ (tzByLabel tzlabel) (LocalTime x midnight)
                       success <- tryInsert $ Course
                                                { courseTitle = title
                                                , courseDescription = unTextarea <$> coursedesc
                                                , courseInstructor = iid
                                                , courseTextbookProblems = Nothing
                                                , courseStartDate = localize startdate
                                                , courseEndDate = localize enddate
                                                , courseTotalPoints = 0
                                                , courseTimeZone = toTZName tzlabel
                                                }
                       case success of Just _ -> setMessage "Course Created"
                                       Nothing -> setMessage "Could not save. Course titles must be unique. Consider adding your instutition or the current semester as a suffix."
                Nothing -> setMessage "you're not an instructor!"
        FormFailure s -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
        FormMissing -> return ()
    case frombookrslt of
        FormSuccess (Entity classkey theclass, theassignment, duedate, mduetime) -> runDB $ do
            let Just tz = tzByName . courseTimeZone $ theclass
                localdue = case mduetime of
                              Just time -> LocalTime duedate time
                              _ -> LocalTime duedate (TimeOfDay 23 59 59)
                due = localTimeToUTCTZ tz localdue
            case readAssignmentTable <$> courseTextbookProblems theclass of
                Just assign -> update classkey [CourseTextbookProblems =. (Just $ BookAssignmentTable $ Data.IntMap.insert theassignment due assign)]
                Nothing -> update classkey [CourseTextbookProblems =. (Just $ BookAssignmentTable $ Data.IntMap.fromList [(theassignment, due)])]
        FormFailure s -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
        FormMissing -> return ()
    case instructorrslt of
        (FormSuccess (cidstring , Just iid)) ->
            case readMaybe cidstring of
                Just cid -> do success <- tryInsert $ CoInstructor iid cid
                               case success of Just _ -> setMessage "Added Co-Instructor!"
                                               Nothing -> setMessage "Co-Instructor seems to already be added"
                Nothing -> setMessage "Couldn't read cid string"
        FormSuccess (_, Nothing) -> setMessage "iid missing"
        FormFailure s -> setMessage $ "Something went wrong: " ++ toMarkup (show s)
        FormMissing -> return ()
    redirect $ InstructorR ident

postInstructorQueryR :: Text -> Handler Value
postInstructorQueryR ident = do
    msg <- requireJsonBody :: Handler InstructorQuery
    case msg of
        QueryGrade uid cid -> do
            score <- scoreByIdAndClassTotal cid uid
            returnJson score
        QueryScores uid cid -> do
            score <- scoreByIdAndClassPerProblem cid uid
            returnJson score

getInstructorR :: Text -> Handler Html
getInstructorR ident = do
    musr <- runDB $ getBy $ UniqueUser ident
    case musr of
        Nothing -> defaultLayout nopage
        (Just (Entity uid _))  -> do
            UserData firstname lastname enrolledin _ _ <- checkUserData uid
            classes <- classesByInstructorIdent ident
            time <- liftIO getCurrentTime
            let activeClasses = filter (\c -> courseEndDate (entityVal c) > time) classes
            let inactiveClasses = filter (\c -> courseEndDate (entityVal c) < time) classes
            docs <- documentsByInstructorIdent ident
            instructors <- runDB $ selectList [UserDataInstructorId !=. Nothing] []
            let labels = map labelOf $ take (length activeClasses) [1 ..]
            classWidgets <- mapM (classWidget ident instructors) activeClasses
            assignmentMetadata <- concat <$> mapM listAssignmentMetadata activeClasses --Get the metadata
            assignmentDocs <- mapM (runDB . get) (map (\(Entity _ v, _) -> assignmentMetadataDocument v) assignmentMetadata)
            documents <- runDB $ selectList [DocumentCreator ==. uid] []
            problemSetLookup <- mapM (\c -> (,)
                                    <$> pure (entityKey c)
                                    <*> (maybe mempty readAssignmentTable
                                        <$> (getProblemSets . entityKey $ c))
                                ) classes
            let assignmentLookup = zipWith (\(Entity k v,_) (Just d) ->
                                                ( k
                                                , documentFilename d
                                                , assignmentMetadataDate v
                                                , assignmentMetadataCourse v
                                                )) assignmentMetadata assignmentDocs
            tagMap <- forM documents $ \doc -> do
                                     tags <- runDB $ selectList [TagBearer ==. entityKey doc] []
                                     return (entityKey doc, map (tagName . entityVal) tags)
            let tagsOf d = lookup d tagMap
                tagString d = case lookup d tagMap of Just tags -> intercalate "," tags; _ -> ""
            (createAssignmentWidget,enctypeCreateAssignment) <- generateFormPost (identifyForm "uploadAssignment" $ uploadAssignmentForm activeClasses docs)
            (uploadDocumentWidget,enctypeShareDocument) <- generateFormPost (identifyForm "uploadDocument" $ uploadDocumentForm)
            (setBookAssignmentWidget,enctypeSetBookAssignment) <- generateFormPost (identifyForm "setBookAssignment" $ setBookAssignmentForm activeClasses)
            (updateAssignmentWidget,enctypeUpdateAssignment) <- generateFormPost (identifyForm "updateAssignment" $ updateAssignmentForm)
            (updateDocumentWidget,enctypeUpdateDocument) <- generateFormPost (identifyForm "updateDocument" $ updateDocumentForm)
            (createCourseWidget,enctypeCreateCourse) <- generateFormPost (identifyForm "createCourse" createCourseForm)
            (updateCourseWidget,enctypeUpdateCourse) <- generateFormPost (identifyForm "updateCourse" $ updateCourseForm)
            defaultLayout $ do
                 addScript $ StaticR js_bootstrap_bundle_min_js
                 addScript $ StaticR js_tagsinput_js
                 addScript $ StaticR js_bootstrap_min_js
                 addStylesheet $ StaticR css_tagsinput_css
                 setTitle $ "Instructor Page for " ++ toMarkup firstname ++ " " ++ toMarkup lastname
                 $(widgetFile "instructor")
    where labelOf = T.append "course-" . pack . show
          mprobsOf course = readAssignmentTable <$> courseTextbookProblems course
          nopage = [whamlet|
                    <div.container>
                        <p> Instructor not found.
                   |]

---------------------
--  Message Types  --
---------------------

data InstructorDelete = DeleteAssignment AssignmentMetadataId
                      | DeleteProblems Text Int
                      | DeleteCourse Text
                      | DeleteDocument Text
                      | DropStudent Text
                      | DeleteCoInstructor CoInstructorId
    deriving Generic

instance ToJSON InstructorDelete

instance FromJSON InstructorDelete

data InstructorQuery = QueryGrade UserId CourseId
                     | QueryScores UserId CourseId
    deriving Generic

instance ToJSON InstructorQuery
instance FromJSON InstructorQuery

------------------
--  Components  --
------------------

uploadAssignmentForm classes docs extra = do
            (fileRes, fileView) <- mreq (selectFieldList docnames) (bfs ("Document" :: Text)) Nothing
            (classRes, classView) <- mreq (selectFieldList classnames) (bfs ("Class" :: Text)) Nothing
            (dueRes,dueView) <- mopt (jqueryDayField def) (withPlaceholder "Date" $ bfs ("Due Date"::Text)) Nothing
            (duetimeRes, duetimeView) <- mopt timeFieldTypeTime (withPlaceholder "Time" $ bfs ("Due Time"::Text)) Nothing
            (fromRes,fromView) <- mopt (jqueryDayField def) (withPlaceholder "Date" $ bfs ("Visible From Date"::Text)) Nothing
            (fromtimeRes, fromtimeView) <- mopt timeFieldTypeTime (withPlaceholder "Time" $ bfs ("Visible From Time"::Text)) Nothing
            (tillRes, tillView) <- mopt (jqueryDayField def) (withPlaceholder "Date" $ bfs ("Visible Until Date"::Text)) Nothing
            (tilltimeRes,tilltimeView) <- mopt timeFieldTypeTime (withPlaceholder "Time" $ bfs ("Visible Until Time"::Text)) Nothing
            (descRes,descView) <- mopt textareaField (bfs ("Assignment Description"::Text)) Nothing
            (passRes,passView) <- mopt textField (bfs ("Password"::Text)) Nothing
            (hiddRes,hiddView) <- mopt checkBoxField (bfs ("Hidden"::Text)) Nothing
            (limitRes,limitView) <- mopt intField (bfs ("Limit"::Text)) Nothing
            currentTime <- lift (liftIO getCurrentTime)
            let theRes = (,,,,,,,,,,,,) <$> fileRes <*> classRes
                                        <*> dueRes  <*> duetimeRes
                                        <*> fromRes <*> fromtimeRes
                                        <*> tillRes <*> tilltimeRes
                                        <*> descRes <*> passRes
                                        <*> hiddRes <*> limitRes
                                        <*> pure currentTime
            let widget = do
                [whamlet|
                #{extra}
                <h6>File to Assign
                <div.row>
                    <div.form-group.col-md-12>
                        ^{fvInput fileView}
                <h6>Assign to
                <div.row>
                    <div.form-group.col-md-12>
                        ^{fvInput classView}
                <h6> Due Date
                <div.row>
                    <div.form-group.col-md-6>
                        ^{fvInput dueView}
                    <div.form-group.col-md-6>
                        ^{fvInput duetimeView}
                <h6> Visible From
                <div.row>
                    <div.form-group.col-md-6>
                        ^{fvInput fromView}
                    <div.form-group.col-md-6>
                        ^{fvInput fromtimeView}
                <h6> Visible To
                <div.row>
                    <div.form-group.col-md-6>
                        ^{fvInput tillView}
                    <div.form-group.col-md-6>
                        ^{fvInput tilltimeView}
                <h6> Description
                <div.row>
                    <div.form-group.col-md-12>
                        ^{fvInput descView}
                <h5> Access Control Settings
                <div.row>
                    <div.col-md-6>
                         <h6> Password
                    <div.col-md-2>
                        <h6> Hide
                    <div.col-md-4>
                        <h6> Minutes Available
                <div.row>
                    <div.form-group.col-md-6>
                        ^{fvInput passView}
                    <div.form-group.col-md-2>
                        <span style="position:relative;top:7px">
                            Hidden:
                        <div style="display:inline-block;width:20px;position:relative;top:10px">
                            ^{fvInput hiddView}
                    <div.form-group.col-md-4>
                        ^{fvInput limitView}
                <p style="color:gray"> Note: all access control options require that you set a password
                |]
            return (theRes,widget)
    where classnames = map (\theclass -> (courseTitle . entityVal $ theclass, theclass)) classes
          docnames = map (\thedoc -> (documentFilename . entityVal $ thedoc, thedoc)) docs

updateAssignmentForm extra = do
            (assignmentRes,assignmentView) <- mreq assignmentId "" Nothing
            (dueRes,dueView) <- mopt (jqueryDayField def) (withPlaceholder "Date" $ bfs ("Due Date"::Text)) Nothing
            (duetimeRes, duetimeView) <- mopt timeFieldTypeTime (withPlaceholder "Time" $ bfs ("Due Time"::Text)) Nothing
            (fromRes,fromView) <- mopt (jqueryDayField def) (withPlaceholder "Date" $ bfs ("Visible From Date"::Text)) Nothing
            (fromtimeRes, fromtimeView) <- mopt timeFieldTypeTime (withPlaceholder "Time" $ bfs ("Visible From Time"::Text)) Nothing
            (tillRes, tillView) <- mopt (jqueryDayField def) (withPlaceholder "Date" $ bfs ("Visible Until Date"::Text)) Nothing
            (tilltimeRes,tilltimeView) <- mopt timeFieldTypeTime (withPlaceholder "Time" $ bfs ("Visible Until Time"::Text)) Nothing
            (descRes,descView) <- mopt textareaField (bfs ("Assignment Description"::Text)) Nothing
            let theRes = (,,,,,,,) <$> assignmentRes
                                   <*> dueRes <*> duetimeRes
                                   <*> fromRes <*> fromtimeRes
                                   <*> tillRes <*> tilltimeRes
                                   <*> descRes
            let widget = do
                [whamlet|
                #{extra}
                ^{fvInput assignmentView}
                <h6> Due Date
                <div.row>
                    <div.form-group.col-md-6>
                        ^{fvInput dueView}
                    <div.form-group.col-md-6>
                        ^{fvInput duetimeView}
                <h6> Visible From
                <div.row>
                    <div.form-group.col-md-6>
                        ^{fvInput fromView}
                    <div.form-group.col-md-6>
                        ^{fvInput fromtimeView}
                <h6> Visible To
                <div.row>
                    <div.form-group.col-md-6>
                        ^{fvInput tillView}
                    <div.form-group.col-md-6>
                        ^{fvInput tilltimeView}
                <h6> Description
                <div.row>
                    <div.form-group.col-md-12>
                        ^{fvInput descView}
                |]
            return (theRes,widget)

    where assignmentId :: (Monad m, RenderMessage (HandlerSite m) FormMessage) => Field m String
          assignmentId = hiddenField

updateAssignmentModal form enc = [whamlet|
                    <div class="modal fade" id="updateAssignmentData" tabindex="-1" role="dialog" aria-labelledby="updateAssignmentDataLabel" aria-hidden="true">
                        <div class="modal-dialog" role="document">
                            <div class="modal-content">
                                <div class="modal-header">
                                    <h5 class="modal-title" id="updateAssignmentDataLabel">Update Assignment Data</h5>
                                    <button type="button" class="close" data-dismiss="modal" aria-label="Close">
                                      <span aria-hidden="true">&times;</span>
                                <div class="modal-body">
                                    <form#updateAssignment enctype=#{enc}>
                                        ^{form}
                                        <div.form-group>
                                            <input.btn.btn-primary type=submit value="update">
                    |]

uploadDocumentForm = renderBootstrap3 BootstrapBasicForm $ (,,,,)
            <$> fileAFormReq (bfs ("Document" :: Text))
            <*> areq (selectFieldList scopes) (bfs ("Share With " :: Text)) Nothing
            <*> aopt textareaField (bfs ("Description"::Text)) Nothing
            <*> lift (liftIO getCurrentTime)
            <*> aopt tagField "Tags" Nothing
    where scopes :: [(Text,SharingScope)]
          scopes = [("Everyone (Visible to everyone)", Public)
                   ,("Instructors (Visible to all instructors)", InstructorsOnly)
                   ,("Link Only (Available, but visible to no one)", LinkOnly)
                   ,("Private (Unavailable)", Private)
                   ]

updateDocumentForm = renderBootstrap3 BootstrapBasicForm $ (,,,,)
            <$> areq docId "" Nothing
            <*> aopt (selectFieldList scopes) (bfs ("Share With " :: Text)) Nothing
            <*> aopt textareaField (bfs ("Description"::Text)) Nothing
            <*> fileAFormOpt (bfs ("Replacement File" :: Text))
            <*> aopt tagField "Tags" Nothing
    where docId :: (Monad m, RenderMessage (HandlerSite m) FormMessage) => Field m String
          docId = hiddenField

          scopes :: [(Text,SharingScope)]
          scopes = [("Everyone (Visible to everyone)", Public)
                   ,("Instructors (Visible to all instructors)", InstructorsOnly)
                   ,("Link Only (Available, but visible to no one)", LinkOnly)
                   ,("Private (Unavailable)", Private)
                   ]

tagField :: Field Handler [Text]
tagField = Field
    { fieldParse = \raw _ -> case raw of [a] -> return $ Right $ Just (T.splitOn "," a);
                                         _ -> return $ Right Nothing
    , fieldView = \idAttr nameAttr _ _ _ ->
             [whamlet|
                <input id=#{idAttr} name=#{nameAttr} data-role="tagsinput">
             |]
    , fieldEnctype = UrlEncoded
    }

updateDocumentModal form enc = [whamlet|
                    <div class="modal fade" id="updateDocumentData" tabindex="-1" role="dialog" aria-labelledby="updateDocumentLabel" aria-hidden="true">
                        <div class="modal-dialog" role="document">
                            <div class="modal-content">
                                <div class="modal-header">
                                    <h5 class="modal-title" id="updateDocumentLabel">Update Shared Document</h5>
                                    <button type="button" class="close" data-dismiss="modal" aria-label="Close">
                                      <span aria-hidden="true">&times;</span>
                                <div class="modal-body">
                                    <form#updateDocument enctype=#{enc}>
                                        ^{form}
                                        <div.form-group>
                                            <input.btn.btn-primary type=submit value="update">
                    |]

setBookAssignmentForm classes extra = do
            (classRes, classView) <- mreq (selectFieldList classnames) (bfs ("Class" :: Text)) Nothing
            (probRes, probView) <- mreq (selectFieldList chapters) (bfs ("Problem Set" :: Text))  Nothing
            (dueRes, dueView) <- mreq (jqueryDayField def) (withPlaceholder "Date" $ bfs ("Due Date"::Text)) Nothing
            (duetimeRes, duetimeView) <- mopt timeFieldTypeTime (withPlaceholder "Time" $ bfs ("Due Time"::Text)) Nothing
            let theRes = (,,,) <$> classRes <*> probRes <*> dueRes <*> duetimeRes
            let widget = do
                [whamlet|
                #{extra}
                <h6>Assign to
                <div.row>
                    <div.form-group.col-md-12>
                        ^{fvInput classView}
                <h6> Problem Set
                <div.row>
                    <div.form-group.col-md-12>
                        ^{fvInput probView}
                <h6> Due Date
                <div.row>
                    <div.form-group.col-md-6>
                        ^{fvInput dueView}
                    <div.form-group.col-md-6>
                        ^{fvInput duetimeView}
                |]
            return (theRes, widget)
    where chapters = map (\x -> ("Problem Set " ++ pack (show x),x)) [1..17] :: [(Text,Int)]
          classnames = map (\theclass -> (courseTitle . entityVal $ theclass, theclass)) classes

createCourseForm = renderBootstrap3 BootstrapBasicForm $ (,,,,)
            <$> areq textField (bfs ("Title" :: Text)) Nothing
            <*> aopt textareaField (bfs ("Course Description"::Text)) Nothing
            <*> areq (jqueryDayField def) (bfs ("Start Date"::Text)) Nothing
            <*> areq (jqueryDayField def) (bfs ("End Date"::Text)) Nothing
            <*> areq (selectFieldList zones)    (bfs ("TimeZone"::Text)) Nothing
    where zones = map (\(x,y,_) -> (decodeUtf8 x,y)) (rights tzDescriptions)

updateCourseModal form enc = [whamlet|
                    <div class="modal fade" id="updateCourseData" tabindex="-1" role="dialog" aria-labelledby="updateCourseDataLabel" aria-hidden="true">
                        <div class="modal-dialog" role="document">
                            <div class="modal-content">
                                <div class="modal-header">
                                    <h5 class="modal-title" id="updateCourseDataLabel">Update Course Data</h5>
                                    <button type="button" class="close" data-dismiss="modal" aria-label="Close">
                                      <span aria-hidden="true">&times;</span>
                                <div class="modal-body">
                                    <form#updateCourse enctype=#{enc}>
                                        ^{form}
                                        <div.form-group>
                                            <input.btn.btn-primary type=submit value="update">
                    |]

updateCourseForm = renderBootstrap3 BootstrapBasicForm $ (,,,,)
            <$> areq courseId "" Nothing
            <*> aopt textareaField (bfs ("Course Description"::Text)) Nothing
            <*> aopt (jqueryDayField def) (bfs ("Start Date"::Text)) Nothing
            <*> aopt (jqueryDayField def) (bfs ("End Date"::Text)) Nothing
            <*> aopt intField (bfs ("Total Points for Course"::Text)) Nothing
    where courseId :: (Monad m, RenderMessage (HandlerSite m) FormMessage) => Field m String
          courseId = hiddenField

addCoInstructorForm instructors cid extra = do
    (courseRes,courseView) <- mreq courseId "" Nothing
    (instRes, instView) <- mreq (selectFieldList $ map toItem instructors) (bfs ("Instructor" :: Text)) Nothing
    let theRes = (,) <$> courseRes <*> instRes
        widget = do
            [whamlet|
            #{extra}
            ^{fvInput courseView}
            <div.input-group>
                ^{fvInput instView}
            <div.input-group>
                <input.btn.btn-primary onclick="submitAddInstructor(this,'#{cid}')" value="Add Co-Instructor">
            |]
    return (theRes,widget)
    where courseId :: (Monad m, RenderMessage (HandlerSite m) FormMessage) => Field m String
          courseId = hiddenField

          toItem (Entity _ i) = (userDataLastName i ++ ", " ++ userDataFirstName i, userDataInstructorId i)

saveTo thedir fn file = do
        datadir <- appDataRoot <$> (appSettings <$> getYesod)
        let path = datadir </> thedir
        liftIO $
            do createDirectoryIfMissing True path
               e <- doesFileExist (path </> fn)
               if e then removeFile (path </> fn) else return ()
               fileMove file (path </> fn)

classWidget :: Text -> [Entity UserData] -> Entity Course ->  HandlerT App IO Widget
classWidget ident instructors classent = do
       let cid = entityKey classent
           course = entityVal classent
           mprobs = readAssignmentTable <$> courseTextbookProblems course :: Maybe (IntMap UTCTime)
       coInstructors <- runDB $ selectList [CoInstructorCourse ==. cid] []
       coInstructorUD <- mapM udByInstructorId (map (coInstructorIdent . entityVal) coInstructors)
       theInstructorUD <- entityVal <$> udByInstructorId (courseInstructor course)
       allUserData <- map entityVal <$> (runDB $ selectList [UserDataEnrolledIn ==. Just cid] [])
       (addCoInstructorWidget,enctypeAddCoInstructor) <- generateFormPost (identifyForm "addCoinstructor" $ addCoInstructorForm instructors (show cid))
       asmd <- runDB $ selectList [AssignmentMetadataCourse ==. cid] []
       asDocs <- mapM (runDB . get) (map (assignmentMetadataDocument . entityVal) asmd)
       let allUids = map userDataUserId allUserData
       musers <- mapM (\x -> runDB (get x)) allUids
       let users = catMaybes musers
       let numberOfUsers = length allUids
           usersAndData = zip users allUserData
           sortedUsersAndData = let lnOf (_,UserData _ ln _ _ _) = ln
                                    in sortBy (\x y -> compare (toLower . lnOf $ x) (toLower . lnOf $ y)) usersAndData
       course <- runDB $ get cid
                  >>= maybe (setMessage "failed to get course" >> notFound) pure
       return [whamlet|
                    <h2>Assignments
                    <div.scrollbox>
                        <table.table.table-striped>
                            <thead>
                                <th> Assignment
                                <th> Due Date
                            <tbody>
                                $maybe probs <- mprobs
                                    $forall (set,due) <- Data.IntMap.toList probs
                                        <tr>
                                            <td>Problem Set #{show set}
                                            <td>#{dateDisplay due course}
                                $forall (Entity k a, Just d) <- zip asmd asDocs
                                    <tr>
                                        <td>
                                            <a href=@{CourseAssignmentR (courseTitle course) (documentFilename d)}>
                                                #{documentFilename d}
                                        $maybe due <- assignmentMetadataDuedate a
                                            <td>#{dateDisplay due course}
                                        $nothing
                                            <td>No Due Date
                    <h2>Students
                    <div.scrollbox
                        data-studentnumber="#{show numberOfUsers}"
                        data-cid="#{jsonSerialize cid}">
                        <table.table.table-striped >
                            <thead>
                                <th> Registered Student
                                <th> Student Name
                                <th> Total Score
                                <th> Action
                            <tbody>
                                $forall (u,UserData fn ln _ _ uid) <- sortedUsersAndData
                                    <tr#student-#{userIdent u}>
                                        <td>
                                            <a href=@{UserR (userIdent u)}>#{userIdent u}
                                        <td>
                                            #{ln}, #{fn}
                                        <td.async
                                            data-query="#{jsonSerialize $ QueryScores uid cid}"
                                            data-email="#{userIdent u}"
                                            data-fn="#{fn}"
                                            data-ln="#{ln}"
                                            data-uid="#{jsonSerialize uid}" >
                                            <span.loading>—
                                        <td>
                                            <button.btn.btn-sm.btn-secondary type="button" title="Drop #{fn} #{ln} from class"
                                                onclick="tryDropStudent('#{jsonSerialize $ DropStudent $ userIdent u}')">
                                                <i.fa.fa-trash-o>
                                            <button.btn.btn-sm.btn-secondary type="button" title="Email #{fn} #{ln}"
                                                onclick="location.href='mailto:#{userIdent u}'">
                                                <i.fa.fa-envelope-o>
                    <h2>Course Data
                    <dl.row>
                        <dt.col-sm-3>Primary Instructor
                        <dd.col-sm-9>#{userDataLastName theInstructorUD}, #{userDataFirstName theInstructorUD}
                        <dt.col-sm-3>Course Title
                        <dd.col-sm-9>#{courseTitle course}
                        $maybe desc <- courseDescription course
                            <dd.col-sm-9.offset-sm-3>#{desc}
                        <dt.col-sm-3>Points Available
                        <dd.col-sm-9>#{courseTotalPoints course}
                        <dt.col-sm-3>Number of Students
                        <dd.col-sm-9>#{numberOfUsers} (Loaded:
                            <span id="loaded-#{jsonSerialize cid}"> 0#
                            )
                        <dt.col-sm-3>Start Date
                        <dd.col-sm-9>#{dateDisplay (courseStartDate course) course}
                        <dt.col-sm-3>End Date
                        <dd.col-sm-9>#{dateDisplay (courseEndDate course) course}
                        <dt.col-sm-3>Time Zone
                        <dd.col-sm-9>#{decodeUtf8 $ courseTimeZone course}
                        <dt.col-sm-3>Enrollment Link
                        <dd.col-sm-9>
                            <a href="@{EnrollR (courseTitle course)}">@{EnrollR (courseTitle course)}
                        $if null coInstructors
                        $else
                            <dt.col-sm-3>Co-Instructors
                            <dd.col-sm-9>
                                $forall (Entity _ coud, Entity ciid _) <- zip coInstructorUD coInstructors
                                    <div#Co-Instructor-#{userDataLastName coud}-#{userDataFirstName coud}>
                                        <i.fa.fa-trash-o
                                            style="cursor:pointer"
                                            title="Remove #{userDataFirstName coud} #{userDataLastName coud} as Co-Instructor"
                                            onclick="tryDeleteCoInstructor('#{jsonSerialize $ DeleteCoInstructor ciid}','#{userDataLastName coud}', '#{userDataFirstName coud}')">
                                        <span>#{userDataFirstName coud},
                                        <span> #{userDataLastName coud}
                    <div.row>
                        <div.col-xl-6.col-lg-12 style="padding:5px">
                            <form.form-inline method=post enctype=#{enctypeAddCoInstructor}>
                                ^{addCoInstructorWidget}
                        <div.col-xl-6.col-lg-12 style="padding:5px">
                            <div.float-xl-right>
                                <button.btn.btn-secondary style="width:160px" type="button"
                                    onclick="modalEditCourse('#{show cid}','#{maybe "" sanatizeForJS (unpack <$> courseDescription course)}','#{dateDisplay (courseStartDate course) course}','#{dateDisplay (courseEndDate course) course}',#{courseTotalPoints course})">
                                    Edit Information
                                <button.btn.btn-secondary style="width:160px" type="button"
                                    onclick="exportGrades('#{jsonSerialize cid}')";">
                                    Export Grades
                                <button.btn.btn-danger style="width:160px" type="button"
                                    onclick="tryDeleteCourse('#{jsonSerialize $ DeleteCourse (courseTitle course)}')">
                                    Delete Course
              |]

dateDisplay utc course = case tzByName $ courseTimeZone course of
                             Just tz  -> formatTime defaultTimeLocale "%F %R %Z" $ utcToZonedTime (timeZoneForUTCTime tz utc) utc
                             Nothing -> formatTime defaultTimeLocale "%F %R UTC" $ utc

maybeDo mv f = case mv of Just v -> f v; _ -> return ()

sanatizeForJS ('\n':xs) = '\\' : 'n' : sanatizeForJS xs
sanatizeForJS ('\\':xs) = '\\' : '\\' : sanatizeForJS xs
sanatizeForJS ('\'':xs) = '\\' : '\'' : sanatizeForJS xs
sanatizeForJS ('"':xs)  = '\\' : '"' : sanatizeForJS xs
sanatizeForJS ('\r':xs) = sanatizeForJS xs
sanatizeForJS (x:xs) = x : sanatizeForJS xs
sanatizeForJS [] = []

-- TODO compare directory contents with database results
listAssignmentMetadata theclass = do asmd <- runDB $ selectList [AssignmentMetadataCourse ==. entityKey theclass] []
                                     return $ map (\a -> (a,theclass)) asmd
