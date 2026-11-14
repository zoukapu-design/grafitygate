import ARKit
import Foundation
import ImageIO
import Supabase
import SwiftUI
import UIKit

/// 写真（gf-media）と場所の記憶（gf-maps）の置き場所。見てよいかはサーバーが決める。
/// 置き場所のフォルダ名はサーバーの auth.uid()::text と同じ小文字の ID（大文字だと断られる）。
struct MediaStore {
    let client: SupabaseClient

    /// 受け取った写真（画面の大きさに縮めたもの）。合わせて 80MB ほどまで
    private static let photos: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()
    private static let fetches = PhotoFetches()

    private static func keep(_ image: UIImage, path: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        photos.setObject(image, forKey: path as NSString, cost: cost)
    }

    /// すでに手もとにある写真（すぐ出せるとき）
    static func cachedPhoto(path: String) -> UIImage? {
        photos.object(forKey: path as NSString)
    }

    // MARK: 写真

    /// 写真を送る（向きを直して縮め、JPEG にし直す＝位置などの付加情報は入らない）。置き場所の名前を返す。
    func uploadPhoto(_ image: UIImage, owner: UUID) async throws -> String {
        guard let data = image.downscaled(maxSide: 1600).jpegData(compressionQuality: 0.82) else {
            throw URLError(.cannotDecodeContentData)
        }
        return try await uploadJPEG(data, owner: owner)
    }

    func uploadJPEG(_ data: Data, owner: UUID) async throws -> String {
        let path = "\(owner.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from("gf-media").upload(path, data: data,
                                                         options: FileOptions(contentType: "image/jpeg"))
        Trace.log("写真を送りました（\(data.count / 1024)KB）")
        if let image = PhotoDecode.image(from: data) { Self.keep(image, path: path) }
        return path
    }

    /// 送ったけれど使わなかった自分の写真を消す（作品を置けなかったときなど。失敗しても続ける）
    func removePhoto(path: String) async {
        do {
            _ = try await client.storage.from("gf-media").remove(paths: [path])
            Self.photos.removeObject(forKey: path as NSString)
        } catch {
            Trace.log("使わなかった写真を消せませんでした：\(ErrorText.of(error))")
        }
    }

    /// アカウントを消す前に、自分のフォルダのファイル（写真・場所の記憶）をすべて消す
    func removeEverything(owner: UUID) async {
        let folder = owner.uuidString.lowercased()
        for bucket in ["gf-media", "gf-maps"] {
            var removed = 0
            for _ in 0..<50 {
                guard let files = try? await client.storage.from(bucket)
                    .list(path: folder, options: SearchOptions(limit: 100)), !files.isEmpty else { break }
                let paths = files.map { "\(folder)/\($0.name)" }
                guard (try? await client.storage.from(bucket).remove(paths: paths)) != nil else { break }
                removed += paths.count
            }
            Trace.log("アカウントの削除：\(bucket) のファイルを \(removed) 個消しました")
        }
        Self.photos.removeAllObjects()
    }

    /// 写真を受け取る（見てよくない写真は、サーバーが断る）
    func photo(path: String) async -> UIImage? {
        if let cached = Self.photos.object(forKey: path as NSString) { return cached }
        // 同じ写真を同時にいくつもの画面が待っていても、受け取るのは 1 回だけ。
        // 縮めて絵にするのは裏で（大きな JPEG をそのまま出すと、スクロールが引っかかる）
        let client = client
        let image = await Self.fetches.image(path: path) {
            try? await client.storage.from("gf-media").download(path: path)
        }
        if let image { Self.keep(image, path: path) }
        return image
    }

    // MARK: 動画と声

    /// 動画・声のファイルを送る（iPhone の中で作り直して、位置などの付加情報を消したもの）。置き場所の名前を返す。
    func uploadFile(_ url: URL, owner: UUID, kind: MemoryMediaKind) async throws -> String {
        try await uploadFile(url, owner: owner, fileExtension: kind.fileExtension,
                             contentType: kind == .video ? "video/mp4" : "audio/mp4", label: kind == .video ? "動画" : "声")
    }

    /// ファイルを送る（拡張子と種類を決めて）。人物の映像は .mov（video/quicktime）
    func uploadFile(_ url: URL, owner: UUID, fileExtension: String, contentType: String, label: String) async throws -> String {
        let data = try Data(contentsOf: url)
        let path = "\(owner.uuidString.lowercased())/\(UUID().uuidString.lowercased()).\(fileExtension)"
        try await client.storage.from("gf-media").upload(path, data: data, options: FileOptions(contentType: contentType))
        Trace.log("\(label)を送りました（\(data.count / 1024)KB）")
        // 送ったものは、そのまま再生できるように手もとに残す
        let local = Self.localURL(for: path)
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: local, options: .atomic)
        return path
    }

    /// 再生のために、動画・声を受け取って手もとのファイルにする（受け取ったものは取っておく）
    func localFile(path: String) async -> URL? {
        let local = Self.localURL(for: path)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard let data = try? await client.storage.from("gf-media").download(path: path) else { return nil }
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: local, options: .atomic)) != nil else { return nil }
        return local
    }

    /// もう手もとにある動画・声のファイル（なければ nil。受け取りはしない）
    func cachedFile(path: String) -> URL? {
        let local = Self.localURL(for: path)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    private static func localURL(for path: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("gf-media", isDirectory: true)
            .appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    // MARK: 場所の記憶

    /// 場所の記憶を縮めて送る（同じ GATE なら上書き）。置き場所の名前と大きさを返す。
    func uploadWorldMap(_ map: ARWorldMap, owner: UUID, gate: UUID) async throws -> (path: String, size: Int) {
        let packed: Data = try MainWatch.run("場所の記憶を縮める") {
            let raw = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
            return try (raw as NSData).compressed(using: .zlib) as Data
        }
        let path = "\(owner.uuidString.lowercased())/\(gate.uuidString.lowercased()).worldmap"
        try await client.storage.from("gf-maps").upload(path, data: packed,
                                                        options: FileOptions(contentType: "application/octet-stream",
                                                                             upsert: true))
        Trace.log("場所の記憶を送りました（\(packed.count / 1024)KB・特徴点 \(map.rawFeaturePoints.points.count) 個・印 \(map.anchors.count) 個）")
        return (path, packed.count)
    }

    func worldMap(path: String) async throws -> ARWorldMap {
        let packed = try await client.storage.from("gf-maps").download(path: path)
        let raw = try (packed as NSData).decompressed(using: .zlib) as Data
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: raw) else {
            throw URLError(.cannotDecodeContentData)
        }
        Trace.log("場所の記憶を受け取りました（\(packed.count / 1024)KB）")
        return map
    }
}

/// サーバーの写真を表示する（見てよくないときは、うすい色の四角のまま）
/// 同じ写真の受け取りを 1 つにまとめる
private actor PhotoFetches {
    private var running: [String: Task<UIImage?, Never>] = [:]

    func image(path: String, fetch: @escaping @Sendable () async -> Data?) async -> UIImage? {
        if let task = running[path] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = await fetch() else { return nil }
            return PhotoDecode.image(from: data)
        }
        running[path] = task
        let image = await task.value
        running[path] = nil
        return image
    }
}

/// 写真を画面に出せる大きさに縮めて、先に絵にしておく（向きも直す）
enum PhotoDecode {
    static func image(from data: Data, maxPixel: CGFloat = 1800) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }
}

struct RemotePhoto: View {
    let path: String
    let contentMode: ContentMode
    let placeholder: Color

    @EnvironmentObject private var session: SessionModel
    @State private var image: UIImage?
    @State private var failed = false

    init(path: String, contentMode: ContentMode = .fill, placeholder: Color = Theme.surfaceElevated) {
        self.path = path
        self.contentMode = contentMode
        self.placeholder = placeholder
        // 手もとにあれば、はじめから出す（一覧を戻ったときにちらつかない）
        _image = State(initialValue: MediaStore.cachedPhoto(path: path))
    }

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.textSecondary.opacity(0.5))
            }
        }
        .clipped()
        .task(id: path) {
            if let cached = MediaStore.cachedPhoto(path: path) {
                image = cached
                return
            }
            image = nil
            failed = false
            let loaded = await session.media?.photo(path: path)
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                failed = loaded == nil
            }
        }
    }
}
