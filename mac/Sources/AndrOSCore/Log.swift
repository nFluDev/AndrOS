import Foundation

/// ~/Library/Logs/AndrOS.log dosyasina yazan basit gunlukcu.
/// GUI uygulamasinda stdout gorunmedigi icin teshis buradan yapilir.
public enum Log {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AndrOS.log")
    }()
    private static let q = DispatchQueue(label: "andros.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    public static func write(_ msg: String) {
        let line = "[\(fmt.string(from: Date()))] \(msg)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
