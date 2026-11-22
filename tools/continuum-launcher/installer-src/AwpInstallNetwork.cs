using System;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;

namespace AwpInstall {
    public static class Network {
        private static HttpWebRequest Request(string address) {
            Uri uri;
            if (!Uri.TryCreate(address, UriKind.Absolute, out uri) || uri.Scheme != "https" || uri.Host != "github.com" ||
                !uri.AbsolutePath.StartsWith("/noahcabral/xr64multiplayer/releases/download/", StringComparison.Ordinal))
                throw new IOException("Unexpected release download address.");
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var request = (HttpWebRequest)WebRequest.Create(uri);
            request.UserAgent = "AWP-Standalone-Launcher";
            request.Timeout = 60000;
            request.ReadWriteTimeout = 60000;
            request.MaximumAutomaticRedirections = 5;
            return request;
        }
        private static HttpWebResponse ReleaseResponse(HttpWebRequest request) {
            var response = (HttpWebResponse)request.GetResponse();
            var uri = response.ResponseUri;
            if (uri.Scheme == "https" && (uri.Host == "github.com" || uri.Host.EndsWith(".githubusercontent.com", StringComparison.Ordinal)))
                return response;
            response.Dispose();
            throw new IOException("The release redirected outside GitHub's download service.");
        }

        public static Stream OpenAsset(Part part) {
            var response = ReleaseResponse(Request(part.Url));
            if (response.ContentLength >= 0 && response.ContentLength != part.Size) {
                response.Dispose();
                throw new InvalidDataException("The release download size does not match GitHub metadata.");
            }
            return new ResponseStream(response);
        }

        public static string UpdateManifest(string url, long size) {
            return ReadUpdateManifest(size, (start, count) => {
                var request = Request(url);
                request.AddRange(start, start + count - 1);
                using (var response = ReleaseResponse(request)) {
                    string expected = String.Format(CultureInfo.InvariantCulture, "bytes {0}-{1}/{2}", start, start + count - 1, size);
                    if (response.StatusCode != HttpStatusCode.PartialContent || response.Headers["Content-Range"] != expected)
                        throw new IOException("GitHub did not supply a verifiable update ZIP range.");
                    var data = new byte[count];
                    using (var stream = response.GetResponseStream()) {
                        for (int offset = 0; offset < count;) {
                            int length = stream.Read(data, offset, count - offset);
                            if (length == 0) throw new IOException("An update ZIP range ended early.");
                            offset += length;
                        }
                    }
                    return data;
                }
            });
        }

        public static string ReadUpdateManifest(long size, Func<long,int,byte[]> readRange) {
            using (var stream = new RangeStream(size, readRange))
            using (var archive = new ZipArchive(stream, ZipArchiveMode.Read)) {
                var manifest = archive.GetEntry("manifest.json");
                if (manifest == null || manifest.Length <= 0 || manifest.Length > 2 * 1024 * 1024)
                    throw new InvalidDataException("Invalid AWP update manifest.");
                using (var reader = new StreamReader(manifest.Open(), Baseline.Utf8)) return reader.ReadToEnd();
            }
        }

        private sealed class ResponseStream : Stream {
            private readonly HttpWebResponse response;
            private readonly Stream source;
            public ResponseStream(HttpWebResponse owner) { response = owner; source = owner.GetResponseStream(); }
            public override int Read(byte[] value, int offset, int count) { return source.Read(value, offset, count); }
            protected override void Dispose(bool disposing) { if (disposing) { source.Dispose(); response.Dispose(); } base.Dispose(disposing); }
            public override bool CanRead { get { return true; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return false; } }
            public override long Length { get { throw new NotSupportedException(); } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] value, int offset, int count) { throw new NotSupportedException(); }
        }

        private sealed class RangeStream : Stream {
            private readonly long length;
            private readonly Func<long,int,byte[]> read;
            private long position;
            private long baseOffset = -1;
            private byte[] bytes;
            private long remaining = 8 * 1024 * 1024;

            public RangeStream(long size, Func<long,int,byte[]> readRange) {
                if (size < 22) throw new InvalidDataException("The update ZIP size is invalid.");
                length = size; read = readRange;
            }
            public override int Read(byte[] value, int offset, int count) {
                if (count == 0 || position >= length) return 0;
                if (baseOffset < 0 || position < baseOffset || position >= baseOffset + bytes.Length) {
                    const int block = 256 * 1024;
                    baseOffset = position / block * block;
                    int size = (int)Math.Min(block, length - baseOffset);
                    remaining -= size;
                    if (remaining < 0) throw new IOException("The update ZIP metadata exceeds the download limit.");
                    bytes = read(baseOffset, size);
                    if (bytes == null || bytes.Length != size) throw new IOException("Invalid update ZIP data range.");
                }
                int fetched = Math.Min(count, bytes.Length - (int)(position - baseOffset));
                Buffer.BlockCopy(bytes, (int)(position - baseOffset), value, offset, fetched);
                position += fetched;
                return fetched;
            }
            public override long Seek(long offset, SeekOrigin origin) {
                long requested = checked((origin == SeekOrigin.Begin ? 0 : origin == SeekOrigin.End ? length : position) + offset);
                if (requested < 0) throw new IOException("The update ZIP has an invalid offset.");
                return position = requested;
            }
            public override bool CanRead { get { return true; } }
            public override bool CanSeek { get { return true; } }
            public override bool CanWrite { get { return false; } }
            public override long Length { get { return length; } }
            public override long Position { get { return position; } set { Seek(value, SeekOrigin.Begin); } }
            public override void Flush() { }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] value, int offset, int count) { throw new NotSupportedException(); }
        }
    }
}
