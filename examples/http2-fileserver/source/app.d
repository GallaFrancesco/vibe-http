import vibe.core.core : runApplication;
import vibe.http.fileserver;
import vibe.http.router;
import vibe.http.server;
import vibe.stream.tls;
import vibe.http.internal.http2.http2 : http2Callback;

void main()
{
	HTTPServerSettings settings;
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1"];

	/// setup TLS context by using cert and key in example rootdir
	settings.tlsContext = createTLSContext(TLSContextKind.server);
	settings.tlsContext.useCertificateChainFile("server.crt");
	settings.tlsContext.usePrivateKeyFile("server.key");

	// set alpn callback to support HTTP/2 protocol negotiation
	settings.tlsContext.alpnCallback(http2Callback);

	auto router = new URLRouter;
	HTTPFileServerSettings fileServerSettings;
	fileServerSettings.encodingFileExtension = ["gzip" : ".gz"];
	router.get("*", serveStaticFiles("./public/",));

	auto l = listenHTTP(settings, router);
	scope (exit) l.stopListening();

	runApplication();
}
