#' Upload a file to RPubs
#'
#' This function publishes a file to rpubs.com. If the upload succeeds a
#' list that includes an `id` and `continueUrl` is returned. A browser
#' should be opened to the `continueUrl` to complete publishing of the
#' document. If an error occurs then a diagnostic message is returned in the
#' `error` element of the list.
#'
#' @param title The title of the document.
#' @param contentFile The path to the content file to upload.
#' @param originalDoc The document that was rendered to produce the
#'   `contentFile`. May be `NULL` if the document is not known.
#' @param id If this upload is an update of an existing document then the id
#'   parameter should specify the document id to update. Note that the id is
#'   provided as an element of the list returned by successful calls to
#'   `rpubsUpload`.
#' @param properties A named list containing additional document properties
#'   (RPubs doesn't currently expect any additional properties, this parameter
#'   is reserved for future use).
#'
#' @return A named list. If the upload was successful then the list contains a
#'   `id` element that can be used to subsequently update the document as
#'   well as a `continueUrl` element that provides a URL that a browser
#'   should be opened to in order to complete publishing of the document. If the
#'   upload fails then the list contains an `error` element which contains
#'   an explanation of the error that occurred.
#'
#' @examples
#' \dontrun{
#' # upload a document
#' result <- rpubsUpload("My document title", "Document.html")
#' if (!is.null(result$continueUrl))
#'    browseURL(result$continueUrl)
#' else
#'    stop(result$error)
#'
#' # update the same document with a new title
#' updateResult <- rpubsUpload("My updated title", "Document.html",
#'                             id = result$id)
#' }
#' @export
rpubsUpload <- function(
  title,
  contentFile,
  originalDoc,
  id = NULL,
  properties = list()
) {
  check_string(title, allow_empty = FALSE)
  check_file(contentFile)
  if (!is.list(properties)) {
    stop("properties paramater must be a named list")
  }

  pathFromId <- function(id) {
    split <- strsplit(id, "^https?://[^/]+")[[1]]
    if (length(split) == 2) {
      return(split[2])
    } else {
      return(NULL)
    }
  }

  buildPackage <- function(title, contentFile, properties = list()) {
    # build package.json
    properties$title <- title
    packageJson <- toJSON(properties)

    # create a tempdir to build the package in and copy the files to it
    fileSep <- .Platform$file.sep
    packageDir <- dirCreate(tempfile())
    packageFile <- function(fileName) {
      paste(packageDir, fileName, sep = fileSep)
    }
    writeLines(packageJson, packageFile("package.json"))
    file.copy(contentFile, packageFile("index.html"))

    # create the tarball
    tarfile <- tempfile("package", fileext = ".tar.gz")
    writeBundle(packageDir, tarfile)

    # return the full path to the tarball
    return(tarfile)
  }

  # build the package
  packageFile <- buildPackage(title, contentFile, properties)

  # determine whether this is a new doc or an update
  isUpdate <- FALSE
  method <- "POST"
  path <- "/api/v1/document"
  headers <- list()
  headers$Connection <- "close"
  if (!is.null(id)) {
    isUpdate <- TRUE
    path <- pathFromId(id)
    method <- "PUT"
  }

  # use https if using a curl R package, and vanilla HTTP otherwise
  http <- httpFunction()
  if (identical(http, httpRCurl) || identical(http, httpLibCurl)) {
    protocol <- "https"
    port <- 443
  } else {
    protocol <- "http"
    port <- 80
  }

  # send the request
  result <- http(
    protocol = protocol,
    host = "api.rpubs.com",
    port = port,
    method = method,
    path = path,
    headers = headers,
    contentType = "application/x-compressed",
    contentFile = packageFile
  )

  # check for success
  succeeded <- FALSE
  if (isUpdate && (result$status == 200)) {
    succeeded <- TRUE
  } else if (result$status == 201) {
    succeeded <- TRUE
  }

  # mark content as UTF-8
  content <- result$content
  Encoding(content) <- "UTF-8"

  # return either id & continueUrl or error
  if (succeeded) {
    parsedContent <- jsonlite::fromJSON(content)
    id <- ifelse(isUpdate, id, result$location)
    url <- as.character(parsedContent["continueUrl"])

    # we use the source doc as the key for the deployment record as long as
    # it's a recognized document path; otherwise we use the content file
    recordSource <- ifelse(
      !is.null(originalDoc) && isDocumentPath(originalDoc),
      originalDoc,
      contentFile
    )

    # use the title if given, and the filename name of the document if not
    recordName <- ifelse(
      is.null(title) || nchar(title) == 0,
      basename(recordSource),
      title
    )

    rpubsRec <- deploymentRecord(
      name = recordName,
      title = "",
      username = "",
      account = "rpubs",
      server = "rpubs.com",
      hostUrl = "rpubs.com",
      appId = id,
      bundleId = id,
      url = url
    )
    rpubsRecFile <- deploymentConfigFile(
      recordSource,
      recordName,
      "rpubs",
      "rpubs.com"
    )
    write.dcf(rpubsRec, rpubsRecFile, width = 4096)

    # record in global history
    if (!is.null(originalDoc) && nzchar(originalDoc)) {
      addToDeploymentHistory(originalDoc, rpubsRec)
    }

    # return the publish information
    return(list(id = id, continueUrl = url))
  } else {
    return(list(error = content))
  }
}
