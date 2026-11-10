import Foundation

// Pictures and files handed to the pet (Capture Float → pet, File Shelf → pet, drops on the pet). They are uploaded
// with `POST /api/v1/media/uploads` (JSON form, nacho-server spec/media.tsp) and sent as `attachments: [{attachment_id}]`.
// What the model can actually see is decided by the server (crates/application/src/services/context/vision.rs):
// jpeg/png/webp/gif up to 5 MB are shown to Nacho, txt/md/csv are read as text, everything else is only stored.

/// An uploaded attachment, as the server returned it.
public struct PetAttachment: Equatable, Codable {
    public var attachmentID: String
    public var kind: String
    public var name: String
    public var mime: String
    public var bytes: Int

    public init(attachmentID: String, kind: String, name: String, mime: String, bytes: Int) {
        self.attachmentID = attachmentID
        self.kind = kind
        self.name = name
        self.mime = mime
        self.bytes = bytes
    }
}

/// A file waiting to be uploaded with the next message.
public struct PetOutgoingFile: Equatable {
    public let name: String
    public let mime: String
    public let kind: String
    public let data: Data

    public var readability: PetMedia.Readability { PetMedia.readability(mime: mime, bytes: data.count) }
}

public enum MediaProblem: Error, Equatable {
    case empty, tooLarge, unsupportedType, tooMany, unauthorized, server(Int), network, badResponse

    public var koreanMessage: String {
        switch self {
        case .empty: return "빈 파일은 보낼 수 없어요."
        case .tooLarge: return "파일이 너무 커요. 한 파일은 \(PetMedia.maxUploadBytes / 1_000_000)MB까지예요."
        case .unsupportedType: return "이 파일 형식은 보낼 수 없어요. 사진·PDF·텍스트(txt·md·csv)·mp4만 보낼 수 있어요."
        case .tooMany: return "한 번에 붙일 수 있는 파일은 \(PetMedia.maxAttachments)개까지예요."
        case .unauthorized: return "로그인이 필요해요."
        case let .server(code): return "파일을 올리지 못했어요. (HTTP \(code))"
        case .network: return "파일을 올리지 못했어요. 네트워크를 확인해 주세요."
        case .badResponse: return "서버 응답을 읽지 못했어요."
        }
    }
}

public enum PetMedia {
    public static let maxAttachments = 4
    /// Server default `media.max_bytes` (20 MB); the server answers 413 above it.
    public static let maxUploadBytes = 20_000_000
    /// The server shows a picture to the model only up to this size (`MAX_IMAGE_BYTES`).
    public static let maxSeenImageBytes = 5 * 1024 * 1024

    public enum Readability: Equatable {
        /// Nacho sees the picture.
        case seen
        /// Nacho reads the beginning of the text.
        case read
        /// Stored with the message; Nacho is told it cannot open it.
        case storedOnly

        public var koreanNote: String {
            switch self {
            case .seen: return "나초가 사진을 볼 수 있어요"
            case .read: return "나초가 글을 읽을 수 있어요"
            case .storedOnly: return "나초는 내용을 열어 보지 못해요 (전달만 돼요)"
            }
        }
    }

    /// Closed table: extension → mime. Anything else is refused before upload.
    public static let mimeByExtension: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown",
        "markdown": "text/markdown", "csv": "text/csv", "mp4": "video/mp4",
    ]

    public static func mime(forFileName name: String) -> String? {
        mimeByExtension[fileExtension(name).lowercased()]
    }

    /// The server's allow-list: image/*, video/mp4 (exactly), application/pdf, text/*.
    public static func isAllowed(mime: String) -> Bool {
        let m = mime.lowercased()
        return m.hasPrefix("image/") || m == "video/mp4" || m == "application/pdf" || m.hasPrefix("text/")
    }

    public static func kind(forMime mime: String) -> String {
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return "image" }
        if m == "video/mp4" { return "video" }
        return "file"
    }

    public static func readability(mime: String, bytes: Int) -> Readability {
        switch mime.lowercased() {
        case "image/jpeg", "image/png", "image/webp", "image/gif": return bytes <= maxSeenImageBytes ? .seen : .storedOnly
        case "text/plain", "text/markdown", "text/csv": return .read
        default: return .storedOnly
        }
    }

    /// True when a picture should be made smaller before upload so that Nacho can see it (captures of big screens).
    public static func shouldShrinkForNacho(mime: String, bytes: Int) -> Bool {
        mime.lowercased().hasPrefix("image/") && bytes > maxSeenImageBytes
    }

    /// File name shown to the server: last path component, control characters removed, at most 120 characters.
    public static func sanitizedName(_ raw: String) -> String {
        let last = raw.split(separator: "/").last.map(String.init) ?? ""
        let clean = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = clean.isEmpty || clean == "." || clean == ".." ? "file" : clean
        if name.count <= 120 { return name }
        let ext = fileExtension(name)
        let keep = 120 - (ext.isEmpty ? 0 : ext.count + 1)
        return String(name.prefix(keep)) + (ext.isEmpty ? "" : "." + ext)
    }

    /// Text after the last dot of the last path component ("" when none, or for names like ".profile").
    public static func fileExtension(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return String(last[last.index(after: dot)...])
    }

    /// Validates a file before it may be attached. `mime` nil = derived from the file name.
    public static func prepare(name: String, data: Data, mime: String? = nil) -> Result<PetOutgoingFile, MediaProblem> {
        let clean = sanitizedName(name)
        guard let m = (mime ?? PetMedia.mime(forFileName: clean))?.lowercased(), isAllowed(mime: m) else {
            return .failure(.unsupportedType)
        }
        if data.isEmpty { return .failure(.empty) }
        if data.count > maxUploadBytes { return .failure(.tooLarge) }
        return .success(PetOutgoingFile(name: clean, mime: m, kind: kind(forMime: m), data: data))
    }

    public static func uploadRequest(_ endpoint: ServerEndpoint, bearer: String?, file: PetOutgoingFile) -> PetHTTPRequest {
        .postJSON(endpoint.rest("/api/v1/media/uploads"), bearer: bearer, json: [
            "kind": file.kind, "name": file.name, "mime": file.mime, "bytes_base64": file.data.base64EncodedString(),
        ])
    }

    public static func decodeUpload(_ data: Data) -> PetAttachment? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any],
              let id = o["attachment_id"] as? String, PetIDs.isUUID(id)
        else { return nil }
        return PetAttachment(attachmentID: id, kind: (o["kind"] as? String) ?? "file", name: (o["name"] as? String) ?? "",
                             mime: (o["mime"] as? String) ?? "", bytes: (o["bytes"] as? Int) ?? 0)
    }

    public static func upload(_ file: PetOutgoingFile, endpoint: ServerEndpoint, bearer: String?, http: PetHTTPClient,
                              completion: @escaping (Result<PetAttachment, MediaProblem>) -> Void) {
        http.send(uploadRequest(endpoint, bearer: bearer, file: file)) { result in
            switch result {
            case .failure: completion(.failure(.network))
            case let .success(resp):
                switch resp.status {
                case 200..<300:
                    if let a = decodeUpload(resp.body) { completion(.success(a)) } else { completion(.failure(.badResponse)) }
                case 401, 403: completion(.failure(.unauthorized))
                case 413: completion(.failure(.tooLarge))
                case 400 where PetServerError.code(resp.body) == "validation_error": completion(.failure(.unsupportedType))
                default: completion(.failure(.server(resp.status)))
                }
            }
        }
    }
}

public enum PetIDs {
    /// 8-4-4-4-12 hex (any version).
    public static func isUUID(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map({ $0.count }) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) } }
    }
}
