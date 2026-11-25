import Foundation
import SharedIPC
import SQLite3

/// 设置中心轻量只读/重置接口（避免 SmartPinyinSetup 依赖 librime）
public struct UserMemorySummary: Equatable, Sendable {
    public let pinyinEntries: Int
    public let contextBigrams: Int
    public let appEntries: Int
    public let learnedPhrases: Int
    public let weightUpdates: Int
    public let fileSizeBytes: Int64

    public static let empty = UserMemorySummary(
        pinyinEntries: 0,
        contextBigrams: 0,
        appEntries: 0,
        learnedPhrases: 0,
        weightUpdates: 0,
        fileSizeBytes: 0
    )

    public var totalEntries: Int {
        pinyinEntries + contextBigrams + appEntries + learnedPhrases
    }
}

public enum UserMemoryInspector {
    public static let memoryResetNotification = Notification.Name(
        "\(SmartPinyinIdentifiers.appBundleID).memoryDidReset"
    )
    public static let workingMemoryClearNotification = Notification.Name(
        "\(SmartPinyinIdentifiers.appBundleID).workingMemoryDidClear"
    )

    public static func databaseURL(baseDirectory: URL? = nil) -> URL {
        let dir = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent(SmartPinyinIdentifiers.appSupportFolderName, isDirectory: true)
        return dir.appendingPathComponent("user_memory.sqlite3")
    }

    public static func inspect(baseDirectory: URL? = nil) -> UserMemorySummary {
        let url = databaseURL(baseDirectory: baseDirectory)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .empty }

        let size = [url,
                    URL(fileURLWithPath: url.path + "-wal"),
                    URL(fileURLWithPath: url.path + "-shm")]
            .reduce(Int64(0)) { acc, file in
                let attrs = try? fm.attributesOfItem(atPath: file.path)
                return acc + ((attrs?[.size] as? Int64) ?? 0)
            }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            if let handle { sqlite3_close(handle) }
            return UserMemorySummary(
                pinyinEntries: 0, contextBigrams: 0, appEntries: 0, learnedPhrases: 0, weightUpdates: 0, fileSizeBytes: size
            )
        }
        defer { sqlite3_close(handle) }

        func scalarInt(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW
            else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }

        return UserMemorySummary(
            pinyinEntries: scalarInt("SELECT COUNT(*) FROM pinyin_prefs;"),
            contextBigrams: scalarInt("SELECT COUNT(*) FROM context_bigrams;"),
            appEntries: scalarInt("SELECT COUNT(*) FROM app_prefs;"),
            learnedPhrases: scalarInt("SELECT COUNT(*) FROM learned_phrases;"),
            weightUpdates: scalarInt("SELECT COALESCE(MAX(update_count), 0) FROM ranker_weights;"),
            fileSizeBytes: size
        )
    }

    public static func clearWorkingMemory() {
        DistributedNotificationCenter.default().postNotificationName(
            workingMemoryClearNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public static func resetAll(baseDirectory: URL? = nil, postNotification: Bool = true) {
        let url = databaseURL(baseDirectory: baseDirectory)
        var handle: OpaquePointer?
        if sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
           let handle {
            _ = sqlite3_exec(
                handle,
                "DELETE FROM pinyin_prefs; DELETE FROM context_bigrams; DELETE FROM app_prefs; DELETE FROM learned_phrases; DELETE FROM ranker_weights; VACUUM;",
                nil,
                nil,
                nil
            )
            sqlite3_close(handle)
        } else {
            if let handle { sqlite3_close(handle) }
            let fm = FileManager.default
            for path in [url.path, url.path + "-wal", url.path + "-shm"] {
                try? fm.removeItem(atPath: path)
            }
        }

        if postNotification {
            DistributedNotificationCenter.default().postNotificationName(
                memoryResetNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }
}
