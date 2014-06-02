
#include "condor_common.h"

#include "compat_classad.h"
#include "condor_version.h"
#include "condor_attributes.h"
#include "file_transfer.h"


#include "dc_cached.h"

DCCached::DCCached(const char * name, const char *pool)
	: Daemon( DT_CACHED, name, pool )
{}

int
DCCached::createCacheDir(std::string &cacheName, time_t &expiry, CondorError &err)
{
	if (!_addr && !locate())
	{
		err.push("CACHED", 2, error() && error()[0] ? error() : "Failed to locate remote cached");
		return 2;
	}

        ReliSock *rsock = (ReliSock *)startCommand(
                CACHED_CREATE_CACHE_DIR, Stream::reli_sock, 20 );
	if (!rsock)
	{
		err.push("CACHED", 1, "Failed to start command to remote cached");
		return 1;
	}

	compat_classad::ClassAd ad;
	std::string version = CondorVersion();
	ad.InsertAttr("CondorVersion", version);
	ad.InsertAttr("LeaseExpiration", expiry);
	ad.InsertAttr("CacheName", cacheName);

	if (!putClassAd(rsock, ad) || !rsock->end_of_message())
	{
		delete rsock;
		err.push("CACHED", 1, "Failed to send request to remote condor_cached");
		return 1;
	}

	ad.Clear();
	rsock->decode();
	if (!getClassAd(rsock, ad) || !rsock->end_of_message())
	{
		delete rsock;
		err.push("CACHED", 1, "Failed to get response from remote condor_cached");
		return 1;
	}

	rsock->close();
	delete rsock;

	int rc;
	if (!ad.EvaluateAttrInt(ATTR_ERROR_CODE, rc))
	{
		err.push("CACHED", 2, "Remote condor_cached did not return error code");
	}

	if (rc)
	{
		std::string error_string;
		if (!ad.EvaluateAttrString(ATTR_ERROR_STRING, error_string))
		{
			err.push("CACHED", rc, "Unknown error from remote condor_cached");
		}
		else
		{
			err.push("CACHED", rc, error_string.c_str());
		}
		return rc;
	}

	std::string new_cacheName;
	time_t new_expiry;
	if (!ad.EvaluateAttrString("CacheName", new_cacheName) || !ad.EvaluateAttrInt("LeaseExpiration", new_expiry))
	{
		err.push("CACHED", 1, "Required attributes (CacheName and LeaseExpiration) not set in server response.");
		return 1;
	}
	cacheName = new_cacheName;
	expiry = new_expiry;
	return 0;
}


int
DCCached::uploadFiles(std::string &cacheName, std::list<std::string> files, CondorError &err)
{
	if (!_addr && !locate())
	{
		err.push("CACHED", 2, error() && error()[0] ? error() : "Failed to locate remote cached");
		return 2;
	}

	ReliSock *rsock = (ReliSock *)startCommand(
					CACHED_UPLOAD_FILES, Stream::reli_sock, 20 );


	if (!rsock)
	{
		err.push("CACHED", 1, "Failed to start command to remote cached");
		return 1;
	}


	compat_classad::ClassAd ad;
	std::string version = CondorVersion();
	ad.InsertAttr("CondorVersion", version);
	ad.InsertAttr("CacheName", cacheName);

	if (!putClassAd(rsock, ad) || !rsock->end_of_message())
	{
		// Can't send another response!  Must just hang-up.
		return 1;
	}

	ad.Clear();
	rsock->decode();
	if (!getClassAd(rsock, ad) || !rsock->end_of_message())
	{
		delete rsock;
		err.push("CACHED", 1, "Failed to get response from remote condor_cached");
		return 1;
	}

	int rc;
	if (!ad.EvaluateAttrInt(ATTR_ERROR_CODE, rc))
	{
		err.push("CACHED", 2, "Remote condor_cached did not return error code");
	}

	if (rc)
	{
		std::string error_string;
		if (!ad.EvaluateAttrString(ATTR_ERROR_STRING, error_string))
		{
			err.push("CACHED", rc, "Unknown error from remote condor_cached");
		}
		else
		{
			err.push("CACHED", rc, error_string.c_str());
		}
		return rc;
	}


	compat_classad::ClassAd transfer_ad;
	transfer_ad.InsertAttr("CondorVersion", version);

	// Expand the files list and add to the classad
	StringList inputFiles;
	inputFiles.insert("/etc/hosts");
	char* filelist = inputFiles.print_to_string();
	transfer_ad.InsertAttr(ATTR_TRANSFER_INPUT_FILES, filelist);
	free(filelist);

	// From here on out, this is the file transfer server socket.
	FileTransfer ft;
  rc = ft.SimpleInit(&transfer_ad, true, true, static_cast<ReliSock*>(rsock));
	if (!rc) {
		dprintf(D_ALWAYS, "Simple init failed");
		return 1;
	}
	ft.setPeerVersion(version.c_str());
	//UploadFilesHandler *handler = new UploadFilesHandler(*this, dirname);
	//ft.RegisterCallback(static_cast<FileTransferHandlerCpp>(&UploadFilesHandler::handle), handler);
	rc = ft.UploadFiles(true);

	if (!rc) {
		dprintf(D_ALWAYS, "Upload files failed.");
		return 1;
	}

	return 0;




}
