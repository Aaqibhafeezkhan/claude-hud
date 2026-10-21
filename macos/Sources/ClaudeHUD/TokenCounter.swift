import AppKit
import Foundation
import HUDCore

// MARK: - Token counting (background, incremental over today's transcripts)

final class TokenCounter {
  private var day = Date.distantPast
  private var offsets: [String: UInt64] = [:]
  private var msgs: [String: [String: (n: Int, today: Bool, cost: Double)]] = [:]
  private var usage: [String: Usage] = [:]
  private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private let marker = Data("\"assistant\"".utf8)

  func scan() -> [String: Usage] {
    let today = Calendar.current.startOfDay(for: Date())
    if today != day { day = today; offsets = [:]; msgs = [:]; usage = [:] }
    let files = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey])
    while let url = files?.nextObject() as? URL {
      guard url.pathExtension == "jsonl",
            let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            mod >= today else { continue }
      read(url.path)
    }
    return usage
  }

  private func read(_ path: String) {
    guard let h = FileHandle(forReadingAtPath: path) else { return }
    defer { try? h.close() }
    var off = offsets[path] ?? 0
    let size = (try? h.seekToEnd()) ?? 0
    if size < off { off = 0; msgs[path] = [:] }
    guard size > off else { return }
    try? h.seek(toOffset: off)
    guard let data = try? h.readToEnd() else { return }
    let complete = TokenMath.completeLines(in: data)
    guard complete.consumedBytes > 0 else { return }
    offsets[path] = off + UInt64(complete.consumedBytes)
    var u = usage[path] ?? Usage()
    var m = msgs[path] ?? [:]
    for line in complete.lines where line.range(of: "\"assistant\"") != nil {
      guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            j["type"] as? String == "assistant", let msg = j["message"] as? [String: Any] else { continue }
      if let parts = msg["content"] as? [[String: Any]],
         let text = parts.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
        u.lastText = text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard let us = msg["usage"] as? [String: Any], let id = msg["id"] as? String else { continue }
      let isToday = (j["timestamp"] as? String).flatMap(iso.date(from:)).map { $0 >= day } ?? true
      let pr = price(msg["model"] as? String ?? "")
      let metrics = TokenMath.parse(
        usage: us,
        inputPrice: pr.i,
        outputPrice: pr.o,
        cacheReadPrice: pr.r
      )
      u.context = metrics.contextTokens
      if m[id] == nil, isToday { u.recache += metrics.recacheTokens }
      if let model = msg["model"] as? String, !model.hasPrefix("<") { u.model = model }
      m[id] = (metrics.totalTokens, isToday, metrics.cost)
    }
    u.tokens = m.values.reduce(0) { $0 + $1.n }
    u.today = m.values.reduce(0) { $0 + ($1.today ? $1.n : 0) }
    u.cost = m.values.reduce(0) { $0 + $1.cost }
    u.todayCost = m.values.reduce(0) { $0 + ($1.today ? $1.cost : 0) }
    msgs[path] = m
    usage[path] = u
  }
}
