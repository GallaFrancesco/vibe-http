module vibe.http.internal.http2.hpack.decoder;

import vibe.http.internal.http2.hpack.huffman;
import vibe.http.internal.http2.hpack.tables;
import vibe.http.internal.http2.hpack.util;
import vibe.http.internal.http2.hpack.exception;

import vibe.internal.array : AllocAppender;
import vibe.core.log;

import std.range; // Decoder
import std.string;
import std.experimental.allocator;
import std.experimental.allocator.mallocator;
import std.exception;

/** Module to implement an header decoder consistent with HPACK specifications (RFC 7541)
  * The detailed description of the decoding process, examples and binary format details can
  * be found at:
  * Section 3: https://tools.ietf.org/html/rfc7541#section-3
  * Section 6: https://tools.ietf.org/html/rfc7541#section-6
  * Appendix C: https://tools.ietf.org/html/rfc7541#appendix-C
*/
alias HTTP2SettingValue = uint;

void decode(I, R, T)(ref I src, ref R dst, ref IndexingTable table,  ref T alloc, ulong maxTableSize=4096) @trusted
{
	ubyte bbuf = src[0];
	src = src[1..$];

	if(bbuf & 128) {
		auto res = decodeInteger(src, bbuf, 7);
		dst.put(table[res]);
	} else {
		HTTP2HeaderTableField hres;
		bool update = false;
		auto adst = AllocAppender!string(alloc);

		if (bbuf & 64) { // inserted in dynamic table
			size_t idx = decodeInteger(src, bbuf, 6);
			if(idx > 0) {  // name == table[index].name, value == literal
				hres.name = table[idx].name;
			} else {   // name == literal, value == literal
				decodeLiteral(src, adst);
				hres.name.setReset(adst);
			}
			decodeLiteral(src, adst);
			hres.value.setReset(adst);
			hres.index = true;
			hres.neverIndex = false;

		} else if(bbuf & 32) {
			update = true;
			auto nsize = decodeInteger(src, bbuf, 3);
			enforce(nsize <= maxTableSize, "Invalid table size update");

			table.updateSize(cast(HTTP2SettingValue)nsize);
			logDebug("Updated dynamic table size to: %d octets", nsize);

		} else if(bbuf & 16) { // NEVER inserted in dynamic table
			size_t idx = decodeInteger(src, bbuf, 4);
			if(idx > 0) {  // name == table[index].name, value == literal
				hres.name = table[idx].name;
			} else {   // name == literal, value == literal
				decodeLiteral(src, adst);
				hres.name.setReset(adst);
			}
			decodeLiteral(src, adst);
			hres.value.setReset(adst);
			hres.index = false;
			hres.neverIndex = true;

		} else { // this occourrence is not inserted in dynamic table
			size_t idx = decodeInteger(src, bbuf, 4);
			if(idx > 0) {  // name == table[index].name, value == literal
				hres.name = table[idx].name;
			} else {   // name == literal, value == literal
				decodeLiteral(src, adst);
				hres.name.setReset(adst);
			}
			decodeLiteral(src, adst);
			hres.value.setReset(adst);
			hres.index = hres.neverIndex = false;

		}
		assert(!(hres.index && hres.neverIndex), "Invalid header indexing information");

		if(!update) dst.put(hres);
	}
}

private void setReset(I,R)(ref I dst, ref R buf)
	if(is(R == AllocAppender!string) || is(R == AllocAppender!(immutable(ubyte)[])))
{
	dst = buf.data;
	buf.reset;
}

private size_t decodeInteger(I)(ref I src, ubyte bbuf, uint nbits) @safe @nogc
{
	auto res = bbuf.toInteger(8-nbits);

	if (res < (1 << nbits) - 1) {
		return res;
	} else {
		uint m = 0;
		do {
			// take another octet
			bbuf = src[0];
			src = src[1..$];
			// concatenate it to the result
			res = res + bbuf.toInteger(1)*(1 << m);
			m += 7;
		} while((bbuf & 128) == 128);
		return res;
	}
}

private void decodeLiteral(I,R)(ref I src, ref R dst) @safe
{
 	enforceHPACK(!src.empty, "Invalid literal header block");

	ubyte bbuf = src[0];
	src = src[1..$];

	bool huffman = (bbuf & 128) ? true : false;

	assert(!src.empty, "Cannot decode from empty range block");

	// take a buffer of remaining octets
	auto vlen = decodeInteger(src, bbuf, 7); // value length
	enforceHPACK(vlen <= src.length, "Invalid literal decoded");

	auto buf = src[0..vlen];
	src = src[vlen..$];

	if(huffman) { // huffman encoded
		decodeHuffman(buf, dst);
	} else { // raw encoded
		dst.put(cast(string)buf);
	}
}
