module vibe.http.internal.http2.http2;

import vibe.http.internal.http2.frame;
import vibe.http.internal.http2.hpack.tables;
import vibe.http.server;

import vibe.core.log;
import vibe.core.net;
import vibe.core.core;
import vibe.core.stream;
import vibe.stream.tls;
import vibe.internal.array;
import vibe.internal.allocator;
import vibe.internal.freelistref;
import vibe.internal.interfaceproxy;

import std.range;
import std.base64;
import std.traits;
import std.bitmanip; // read from ubyte (decoding)
import std.typecons;
import std.conv : to;
import std.exception : enforce;
import std.algorithm : canFind; // alpn callback
import std.variant : Algebraic;

/*
 *  6.5.1.  SETTINGS Format
 *
 *   The payload of a SETTINGS frame consists of zero or more parameters,
 *   each consisting of an unsigned 16-bit setting identifier and an
 *   unsigned 32-bit value.
 *
 *   +-------------------------------+
 *   |	   IDentifier (16)		 |
 *   +-------------------------------+-------------------------------+
 *   |						Value (32)							 |
 *   +---------------------------------------------------------------+
 *						Figure 10: Setting Format
 *
 *   6.5.2.  Defined SETTINGS Parameters
 *
 *   The following parameters are defined:
 *
 *   SETTINGS_HEADER_TABLE_SIZE (0x1):  Allows the sender to inform the
 *	 remote endpoint of the maximum size of the header compression
 *	 table used to decode header blocks, in octets.  The encoder can
 *	 select any size equal to or less than this value by using
 *	 signaling specific to the header compression format inside a
 *	 header block (see [COMPRESSION]).  The initial value is 4,096
 *	 octets.
 *
 *   SETTINGS_ENABLE_PUSH (0x2):  This setting can be used to disable
 *	  server push (Section 8.2).  An endpoint MUST NOT send a
 *	  PUSH_PROMISE frame if it receives this parameter set to a value of
 *	  0.  An endpoint that has both set this parameter to 0 and had it
 *	  acknowledged MUST treat the receipt of a PUSH_PROMISE frame as a
 *	  connection error (Section 5.4.1) of type PROTOCOL_ERROR.
 *
 *	  The initial value is 1, which indicates that server push is
 *	  permitted.  Any value other than 0 or 1 MUST be treated as a
 *	  connection error (Section 5.4.1) of type PROTOCOL_ERROR.
 *
 *	SETTINGS_MAX_CONCURRENT_STREAMS (0x3):  Indicates the maximum number
 *	  of concurrent streams that the sender will allow.  This limit is
 *	  directional: it applies to the number of streams that the sender
 *	  permits the receiver to create.  Initially, there is no limit to
 *	  this value.  It is recommended that this value be no smaller than
 *	  100, so as to not unnecessarily limit parallelism.
 *
 *	  A value of 0 for SETTINGS_MAX_CONCURRENT_STREAMS SHOULD NOT be
 *	  treated as special by endpoints.  A zero value does prevent the
 *	  creation of new streams; however, this can also happen for any
 *	  limit that is exhausted with active streams.  Servers SHOULD only
 *	  set a zero value for short durations; if a server does not wish to
 *	  accept requests, closing the connection is more appropriate.
 *
 *	SETTINGS_INITIAL_WINDOW_SIZE (0x4):  Indicates the sender's initial
 *	   window size (in octets) for stream-level flow control.  The
 *	   initial value is 2^16-1 (65,535) octets.
 *
 *	   This setting affects the window size of all streams (see
 *	   Section 6.9.2).
 *
 *	   Values above the maximum flow-control window size of 2^31-1 MUST
 *	   be treated as a connection error (Section 5.4.1) of type
 *	   FLOW_CONTROL_ERROR.
 *
 *	SETTINGS_MAX_FRAME_SIZE (0x5):  Indicates the size of the largest
 *	   frame payload that the sender is willing to receive, in octets.
 *
 *	   The initial value is 2^14 (16,384) octets.  The value advertised
 *	   by an endpoint MUST be between this initial value and the maximum
 *	   allowed frame size (2^24-1 or 16,777,215 octets), inclusive.
 *	   Values outside this range MUST be treated as a connection error
 *	   (Section 5.4.1) of type PROTOCOL_ERROR.
 *
 *	SETTINGS_MAX_HEADER_LIST_SIZE (0x6):  This advisory setting informs a
 *	   peer of the maximum size of header list that the sender is
 *	   prepared to accept, in octets.  The value is based on the
 *	   uncompressed size of header fields, including the length of the
 *	   name and value in octets plus an overhead of 32 octets for each
 *	   header field.
 *
 *	   For any given request, a lower limit than what is advertised MAY
 *	   be enforced.  The initial value of this setting is unlimited.
 *
 *   An endpoint that receives a SETTINGS frame with any unknown or
 *   unsupported identifier MUST ignore that setting.
*/
version = VibeForceALPN;

alias HTTP2SettingID = ushort;
alias HTTP2SettingValue = uint;

// useful for bound checking
const HTTP2SettingID minID = 0x1;
const HTTP2SettingID maxID = 0x6;

enum  HTTP2SettingsParameter {
	headerTableSize				 = 0x1,
	enablePush					  = 0x2,
	maxConcurrentStreams			= 0x3,
	initialWindowSize			   = 0x4,
	maxFrameSize					= 0x5,
	maxHeaderListSize			   = 0x6
}

// UDAs
struct HTTP2Setting {
	HTTP2SettingID id;
	string name;
}

// UDAs
HTTP2Setting http2Setting(HTTP2SettingID id, string name) {
	if (!__ctfe) assert(false, "May only be used as a UDA");
	return HTTP2Setting(id, name);
}

struct HTTP2Settings {

	// no limit specified in the RFC
	@http2Setting(0x1, "SETTINGS_HEADER_TABLE_SIZE")
	HTTP2SettingValue headerTableSize = 4096;

	// TODO {0,1} otherwise CONNECTION_ERROR
	@http2Setting(0x2, "SETTINGS_ENABLE_PUSH")
	HTTP2SettingValue enablePush = 1;

	/* set to the max value (UNLIMITED)
	 * TODO manage connection with value == 0
	 * might be closed as soon as possible
	 */
	@http2Setting(0x3, "SETTINGS_MAX_CONCURRENT_STREAMS")
	HTTP2SettingValue maxConcurrentStreams = HTTP2SettingValue.max;

	// TODO FLOW_CONTROL_ERRROR on values > 2^31-1
	@http2Setting(0x4, "SETTINGS_INITIAL_WINDOW_SIZE")
	HTTP2SettingValue initialWindowSize = 65535;

	// TODO PROTOCOL_ERROR on values > 2^24-1
	@http2Setting(0x5, "SETTINGS_MAX_FRAME_SIZE")
	HTTP2SettingValue maxFrameSize = 16384;

	// set to the max value (UNLIMITED)
	@http2Setting(0x6, "SETTINGS_MAX_HEADER_LIST_SIZE")
	HTTP2SettingValue maxHeaderListSize = HTTP2SettingValue.max;

	/**
	 * Use Decoder to decode a string and set the corresponding settings
	 * The decoder must follow the base64url encoding
	 * `bool` since the handler must ignore the Upgrade request
	 * if the settings cannot be decoded
	 */
	bool decode(alias Decoder)(string encodedSettings) @safe
		if (isInstanceOf!(Base64Impl, Decoder))
	{
		ubyte[] uset;
		try {
			// the Base64URL decoder throws a Base64exception if it fails
			uset = Decoder.decode(encodedSettings);
			enforce!Base64Exception(uset.length % 6 == 0, "Invalid SETTINGS payload length");
		} catch (Base64Exception e) {
			logDiagnostic("Failed to decode SETTINGS payload: " ~ e.msg);
			return false;
		}

		// set values
		while(!uset.empty) m_set(uset.read!HTTP2SettingID, uset.read!HTTP2SettingValue);
		return true;
	}

	/*
	 * Set parameter 'id' to 'value'
	 * private overload for decoded parameters assignment
	 */
	void set(HTTP2SettingID id)(HTTP2SettingValue value) @safe
		if(id <= maxID && id >= minID)
	{
		m_set(id,value);
	}

	private void m_set(HTTP2SettingID id, HTTP2SettingValue value) @safe
	{
		// must use labeled break w. static foreach
		assign: switch(id) {
			default: logWarn("Unsupported SETTINGS code:" ~ to!string(id)); return;
			static foreach(c; __traits(allMembers, HTTP2SettingsParameter)) {
				case __traits(getMember, HTTP2SettingsParameter, c):
					__traits(getMember, this, c) = value;
					break assign;
			}
		}
	}

}

void serializeSettings(R)(ref R dst, HTTP2Settings settings) @safe @nogc
{
	static foreach(s; __traits(allMembers, HTTP2Settings)) {
		static if(is(typeof(__traits(getMember, HTTP2Settings, s)) == HTTP2SettingValue)) {
			mixin("dst.putBytes!2((getUDAs!(settings."~s~",HTTP2Setting)[0]).id);");
			mixin("dst.putBytes!4(settings."~s~");");
		}
	}
}

void unpackSettings(R)(ref HTTP2Settings settings, R src) @safe @nogc
{
	while(!src.empty) {
		auto id = src.takeExactly(2).fromBytes(2);
		src.popFrontN(2);
		static foreach(s; __traits(allMembers, HTTP2Settings)) {
			static if(is(typeof(__traits(getMember, HTTP2Settings, s)) == HTTP2SettingValue)) {
				mixin("if(id == ((getUDAs!(settings."~s~",HTTP2Setting)[0]).id)) {
							settings."~s~" = src.takeExactly(4).fromBytes(4);
							src.popFrontN(4);
						}");

			}
		}
	}
}

unittest {

	HTTP2Settings settings;

	// retrieve a value
	assert(settings.headerTableSize == 4096);

	//set a SETTINGS value using the enum table
	settings.set!(HTTP2SettingsParameter.headerTableSize)(2048);
	assert(settings.headerTableSize == 2048);

	//set a SETTINGS value using the code directly
	settings.set!0x4(1024);
	assert(settings.initialWindowSize == 1024);

	// SHOULD NOT COMPILE
	//settings.set!0x7(1);

	// get a HTTP2Setting struct containing the code and the parameter name
	import std.traits : getUDAs;
	assert(getUDAs!(settings.headerTableSize, HTTP2Setting)[0] == HTTP2Setting(0x1,
				"SETTINGS_HEADER_TABLE_SIZE"));

	// test decoding from base64url
	// h2settings contains:
	// 0x2 -> 0
	// 0x3 -> 100
	// 0x4 -> 1073741824
	string h2settings = "AAMAAABkAARAAAAAAAIAAAAA";
	assert(settings.decode!Base64URL(h2settings));

	assert(settings.enablePush == 0);
	assert(settings.maxConcurrentStreams == 100);
	assert(settings.initialWindowSize == 1073741824);

	// should throw a Base64Exception error (caught) and a logWarn
	assert(!settings.decode!Base64URL("a|b+*-c"));
}


/*
   3.2.  Starting HTTP/2 for "http" URIs

   A client that makes a request for an "http" URI without prior
   knowledge about support for HTTP/2 on the next hop uses the HTTP
   Upgrade mechanism (Section 6.7 of [RFC7230]).  The client does so by
   making an HTTP/1.1 request that includes an Upgrade header field with
   the "h2c" token.  Such an HTTP/1.1 request MUST include exactly one
   HTTP2-Settings (Section 3.2.1) header field.

   For example:

	 GET / HTTP/1.1
	 Host: server.example.com
	 Connection: Upgrade, HTTP2-Settings
	 Upgrade: h2c
	 HTTP2-Settings: <base64url encoding of HTTP/2 SETTINGS payload>

   Requests that contain a payload body MUST be sent in their entirety
   before the client can send HTTP/2 frames.  This means that a large
   request can block the use of the connection until it is completely
   sent.

   If concurrency of an initial request with subsequent requests is
   important, an OPTIONS request can be used to perform the upgrade to
   HTTP/2, at the cost of an additional round trip.


   A server that does not support HTTP/2 can respond to the request as
   though the Upgrade header field were absent:

	 HTTP/1.1 200 OK
	 Content-Length: 243
	 Content-Type: text/html

	 ...

   A server MUST ignore an "h2" token in an Upgrade header field.
   Presence of a token with "h2" implies HTTP/2 over TLS, which is
   instead negotiated as described in Section 3.3.

   A server that supports HTTP/2 accepts the upgrade with a 101
   (Switching Protocols) response.  After the empty line that terminates
   the 101 response, the server can begin sending HTTP/2 frames.  These
   frames MUST include a response to the request that initiated the
   upgrade.

   For example:

	 HTTP/1.1 101 Switching Protocols
	 Connection: Upgrade
	 Upgrade: h2c

	 [ HTTP/2 connection ...

   The first HTTP/2 frame sent by the server MUST be a server connection
   preface (Section 3.5) consisting of a SETTINGS frame (Section 6.5).
   Upon receiving the 101 response, the client MUST send a connection
   preface (Section 3.5), which includes a SETTINGS frame.

   The HTTP/1.1 request that is sent prior to upgrade is assigned a
   stream identifier of 1 (see Section 5.1.1) with default priority
   values (Section 5.3.5).  Stream 1 is implicitly "half-closed" from
   the client toward the server (see Section 5.1), since the request is
   completed as an HTTP/1.1 request.  After commencing the HTTP/2
   connection, stream 1 is used for the response.

3.2.1.  HTTP2-Settings Header Field

   A request that upgrades from HTTP/1.1 to HTTP/2 MUST include exactly
   one "HTTP2-Settings" header field.  The HTTP2-Settings header field
   is a connection-specific header field that includes parameters that
   govern the HTTP/2 connection, provided in anticipation of the server
   accepting the request to upgrade.

	 HTTP2-Settings	= token68

   A server MUST NOT upgrade the connection to HTTP/2 if this header
   field is not present or if more than one is present.  A server MUST
   NOT send this header field.

   The content of the HTTP2-Settings header field is the payload of a
   SETTINGS frame (Section 6.5), encoded as a base64url string (that is,
   the URL- and filename-safe Base64 encoding described in Section 5 of
   [RFC4648], with any trailing '=' characters omitted).  The ABNF
   [RFC5234] production for "token68" is defined in Section 2.1 of
   [RFC7235].

   Since the upgrade is only intended to apply to the immediate
   connection, a client sending the HTTP2-Settings header field MUST
   also send "HTTP2-Settings" as a connection option in the Connection
   header field to prevent it from being forwarded (see Section 6.1 of
   [RFC7230]).

   A server decodes and interprets these values as it would any other
   SETTINGS frame.  Explicit acknowledgement of these settings
   (Section 6.5.3) is not necessary, since a 101 response serves as
   implicit acknowledgement.  Providing these values in the upgrade
   request gives a client an opportunity to provide parameters prior to
   receiving any frames from the server.

*/


/*
 * Check if SETTINGS payload is valid by trying to decode it
 * if !valid, close connection and refuse to upgrade (RFC) - TODO discuss
 * if valid, send SWITCHING_PROTOCOL response and start an HTTP/2 connection handler
 */
bool startHTTP2Connection(ConnectionStream)(ConnectionStream connection, string h2settings,
		HTTP2ServerContext context, HTTPServerResponse switchRes) @safe
	if (isConnectionStream!ConnectionStream)
{
	// init settings
	HTTP2Settings settings;
	logInfo("Starting HTTP/2 connection");

	// try decoding settings
	if (settings.decode!Base64URL(h2settings)) {
		// send response
		context.settings = settings;
		switchRes.switchToHTTP2(&handleHTTP2Connection!ConnectionStream, context);
		return true;
	} else {
		// reply with a 400 (bad request) header
		switchRes.sendBadRequest();
		connection.close;
		return false;
	}
}

unittest {
	import vibe.core.core : runApplication;
	// empty handler, just to test if protocol switching works
	void handleReq(HTTPServerRequest req, HTTPServerResponse res)
	@safe {
		if (req.path == "/")
		res.writeBody("Hello, World! This response is sent through HTTP/2");
	}

	auto settings = HTTPServerSettings();
	settings.port = 8090;
	settings.bindAddresses = ["localhost"];

	listenHTTP!handleReq(settings);
	//runApplication();
}

unittest {
	//import vibe.core.core : runApplication;

	void handleRequest (HTTPServerRequest req, HTTPServerResponse res)
	@safe {
		if (req.path == "/")
		res.writeBody("Hello, World! This response is sent through HTTP/2");
	}


	HTTPServerSettings settings;
	settings.port = 8091;
	settings.bindAddresses = ["127.0.0.1"];
	settings.tlsContext = createTLSContext(TLSContextKind.server);
	settings.tlsContext.useCertificateChainFile("tests/server.crt");
	settings.tlsContext.usePrivateKeyFile("tests/server.key");

	// set alpn callback to support HTTP/2
	// should accept the 'h2' protocol request
	settings.tlsContext.alpnCallback = http2Callback;

	// dummy, just for testing
	listenHTTP!handleRequest(settings);
	runApplication();
}

/**
  * an ALPN callback which can be used to detect the "h2" protocol
  * must be set before initializing the server with 'listenHTTP'
  * if the protocol is not set, it replies with HTTP/1.1
  */
TLSALPNCallback http2Callback = (string[] choices) {
	logInfo("http2Callback");
	if (choices.canFind("h2")) return "h2";
	else return "http/1.1";
};

private alias TLSStreamType = ReturnType!(createTLSStreamFL!(InterfaceProxy!Stream));

/** server & client should send a connection preface
  * server should receive a connection preface from the client
  * server connection preface consists of a SETTINGS Frame
  */
void handleHTTP2Connection(ConnectionStream)(ConnectionStream stream, TCPConnection connection, HTTP2ServerContext context) @safe
	if (isConnectionStream!ConnectionStream || is(ConnectionStream : TLSStreamType))
{
	logInfo("HTTP/2 Connection Handler");

	// read the connection preface
	ubyte[24] h2connPreface;
	stream.read(h2connPreface);

	assert(h2connPreface == "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", "Invalid HTTP/2 h2stream preface");
	logInfo("Received client h2stream preface");

	// send SETTINGS Frame
	ubyte[45] settingBuf;
	FixedAppender!(ubyte[], HTTP2HeaderLength+36) settingDst;
	settingDst.createHTTP2FrameHeader(36, HTTP2FrameType.SETTINGS, 0x0, 0);
	settingDst.serializeSettings(context.settings);
	stream.write(settingDst.data);

	() @trusted {
		IndexingTable table = IndexingTable(context.settings.headerTableSize);
		handleHTTP2FrameChain(connection, context);
	} ();
}

private void handleHTTP2FrameChain(ConnectionStream)(ConnectionStream connection, HTTP2ServerContext context) @safe
	if (isConnectionStream!ConnectionStream || is(ConnectionStream : TLSStream))
{
	logInfo("HTTP/2 Frame Chain Handler");

	static struct CB {
		ConnectionStream connection;
		HTTP2ServerContext context;

		void opCall(bool st)
		{
			if (!st) connection.close;
			else runTask(&handleHTTP2FrameChain, connection, context);
		}
	}

	while(true) {
		CB cb = {connection, context};
		auto st = connection.waitForDataAsync(cb);

		final switch(st) {
			case WaitForDataAsyncStatus.waiting: return;
			case WaitForDataAsyncStatus.noMoreData: connection.close; return;
			case WaitForDataAsyncStatus.dataAvailable: handleHTTP2Frame(connection, context); break;
		}
	}
}

private void handleHTTP2Frame(ConnectionStream)(ConnectionStream connection, HTTP2ServerContext context) @safe
	if (isConnectionStream!ConnectionStream || is(ConnectionStream : TLSStream))
{
	logInfo("HTTP/2 Frame Handler");
	auto h2stream = HTTP2ConnectionStream!ConnectionStream(connection, context.next_sid);

	() @trusted {

		import vibe.internal.utilallocator: RegionListAllocator;
		version (VibeManualMemoryManagement)
			scope alloc = new RegionListAllocator!(shared(Mallocator), false)(1024, Mallocator.instance);
		else
			scope alloc = new RegionListAllocator!(shared(GCAllocator), true)(1024, GCAllocator.instance);
		handleFrameAlloc(h2stream, context, alloc);

	} ();

}

private void handleFrameAlloc(ConnectionStream)(ConnectionStream stream, HTTP2ServerContext context, IAllocator alloc) @safe
{
	logInfo("HTTP/2 Frame Handler (Alloc)");

	// payload buffer
	auto rawBuf = AllocAppender!(ubyte[])(alloc);
	auto payload = AllocAppender!(ubyte[])(alloc);

	// Frame properties
	bool endStream = false;
	bool needsCont = false;
	bool isAck = false;
	HTTP2FrameStreamDependency sdep;

	// read header
	stream.readHeader(rawBuf);
	auto len = rawBuf.data[0..3].fromBytes(3);

	// adjust buffer sizes
	rawBuf.reserve(len);
	payload.reserve(len);

	// read payload
	stream.readPayload(rawBuf, len);

	// parse frame
	auto header = payload.unpackHTTP2Frame(rawBuf.data, endStream, needsCont, isAck, sdep);

	logInfo("Received: "~to!string(header.type)~" on streamID "~to!string(header.streamId));

	// build reply according to frame type
	final switch(header.type) {
		case HTTP2FrameType.DATA:
			if(endStream) {
				// close stream `stream.streamId`
			}
			break;

		case HTTP2FrameType.HEADERS:
			if(sdep.isSet) {
				// update stream dependency with data in `sdep`
			}
			if(needsCont) {
				// wait for the next header frame until end_headers flag is set
				// END_STREAM flag does not count in this case
			}
			if(endStream) {
				// close stream `stream.streamId`
			}
			break;

		case HTTP2FrameType.PRIORITY:
			// update stream dependency with data in `sdep`
			break;

		case HTTP2FrameType.RST_STREAM:
			// reset stream in `closed` state
			// payload contains error code
			break;

		case HTTP2FrameType.SETTINGS:
			if(!isAck) {
				// parse settings payload
				context.settings.unpackSettings(payload.data);
				// acknowledge settings with SETTINGS ACK Frame
				FixedAppender!(ubyte[], 9) ackReply;
				ackReply.createHTTP2FrameHeader(0, header.type, 0x1, header.streamId);
				stream.write(ackReply.data);
				logInfo("Sent SETTINGS ACK");
			}
			break;

		case HTTP2FrameType.PUSH_PROMISE:
			// reserve a streamId to be created (in payload)
			// if not possible, CONNECTION_ERROR (invalid stream id)
			//
			// process header sent (in payload)
			if(needsCont) {
				// wait for the next header frame until end_headers flag is set
			}
			break;

		case HTTP2FrameType.PING:
			if(!isAck) {
				// acknowledge ping with PING ACK Frame
				rawBuf.reserve(HTTP2HeaderLength + len);
				rawBuf.createHTTP2FrameHeader(len, header.type, 0x1, header.streamId);
				rawBuf.buildHTTP2Frame(payload.data);

				stream.write(rawBuf.data);
			}
			break;

		case HTTP2FrameType.GOAWAY: // GOAWAY is used to close connection (in handler)
			// set LAST_STREAM_ID to the received value
			// report error code & additional debug info
			// respond with GOAWAY
			//rawBuf.reserve(HTTP2HeaderLength + len);
			//rawBuf.createHTTP2FrameHeader(len, header.type, 0x0, 0);
			//rawBuf.buildHTTP2Frame(payload.data);
			//stream.write(rawBuf.data);
			// terminate connection
			//stream.close();
			break;

		case HTTP2FrameType.WINDOW_UPDATE:
			// TODO per-stream and connection-based flow control
			// window size is a uint (31) in payload
			// update window size for DATA Frames flow control
			break;

		case HTTP2FrameType.CONTINUATION:
			// process header block fragment in payload
			if(needsCont) {
				// wait for the next header frame until end_headers flag is set
			}
			break;
	}
}

enum HTTP2StreamState {
	IDLE,
	RESERVED_LOCAL,
	RESERVED_REMOTE,
	OPEN,
	HALF_CLOSED_LOCAL,
	HALF_CLOSED_REMOTE,
	CLOSED
}

struct HTTP2ServerContext
{
	private {
		HTTPServerContext m_context;
		Nullable!HTTP2Settings m_settings;
		uint m_sid = 2;
		bool m_isTLS = true;
	}

	// used to mantain the first request in case of `h2c` protocol switching
	Nullable!(ubyte[]) resHeader;
	Nullable!(ubyte[]) resBody;

	this(HTTPServerContext ctx, HTTP2Settings settings) @safe
	{
		m_context = ctx;
		m_settings = settings;
	}

	this(HTTPServerContext ctx) @safe
	{
		m_context = ctx;
	}

	alias m_context this;

	@property uint next_sid() @safe @nogc { assert(m_sid % 2 == 0); m_sid += 2; return m_sid; }

	@property bool isTLS() @safe @nogc { return m_isTLS; }

	@property void setNoTLS() @safe @nogc { m_isTLS = false; }

	@property ref HTTP2Settings settings() @safe @nogc
	{
		assert(!m_settings.isNull);
		return m_settings;
	}

	@property void settings(ref HTTP2Settings settings) @safe @nogc
	{
		assert(m_settings.isNull);
		m_settings = settings;
	}
}

// based on TCPConnection
// added methods for compliance with the Stream class
struct HTTP2ConnectionStream(CS)
{
	static assert(isConnectionStream!CS || is(CS : TLSStream) || isOutputStream!Stream);

	private {
		enum Parse { HEADER, PAYLOAD };
		CS m_conn;
		const uint m_streamId; // streams initiated by the server must be even-numbered
		Parse toParse = Parse.HEADER;

		// TODO manage the underlying HTTP/1.1 request
		HTTPServerRequest m_req;
		HTTPServerResponse m_res;
	}

	alias m_conn this;
	HTTP2StreamState state;

	this(CS)(ref CS conn, uint sid) @safe
	{
		m_conn = conn;
		m_streamId = sid;
		state = HTTP2StreamState.IDLE;
	}

	this(CS)(ref CS conn) @safe
	{
		this(conn, 0);
	}

	@property uint streamId() @safe @nogc { return m_streamId; }

	void readHeader(R)(ref R dst) @safe
	{
		assert(toParse == Parse.HEADER);
		toParse = Parse.PAYLOAD;

		ubyte[9] buf;
		m_conn.read(buf);
		dst.put(buf);
	}

	void readPayload(R)(ref R dst, int len) @safe
	{
		assert(toParse == Parse.PAYLOAD);
		toParse = Parse.HEADER;

		ubyte[8] buf = void;
		while(len > 0) {
			auto end = (len < buf.length) ? len : buf.length;
			len -= m_conn.read(buf[0..end], IOMode.all);
			dst.put(buf[0..end]);
		}
	}
}

unittest {
	TCPConnection c;
	auto h2 = HTTP2ConnectionStream!TCPConnection(c, 1);

	assert(h2.empty);
	assert(h2.streamId == 1);
}
