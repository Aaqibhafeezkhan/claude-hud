import Foundation

public struct TokenMetrics: Equatable {
  public let cacheWriteTokens: Int
  public let totalTokens: Int
  public let contextTokens: Int
  public let cost: Double
  public let recacheTokens: Int
}

public enum TokenMath {
  public static func parse(
    line: String,
    inputPrice: Double,
    outputPrice: Double,
    cacheReadPrice: Double
  ) -> TokenMetrics? {
    guard let data = line.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          root["type"] as? String == "assistant",
          let message = root["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any] else { return nil }

    return parse(
      usage: usage,
      inputPrice: inputPrice,
      outputPrice: outputPrice,
      cacheReadPrice: cacheReadPrice
    )
  }

  public static func parse(
    usage: [String: Any],
    inputPrice: Double,
    outputPrice: Double,
    cacheReadPrice: Double
  ) -> TokenMetrics {
    func count(_ key: String) -> Int {
      max(0, usage[key] as? Int ?? 0)
    }

    let input = count("input_tokens")
    let output = count("output_tokens")
    let cacheWrite = count("cache_creation_input_tokens")
    let cacheRead = count("cache_read_input_tokens")
    let oneHourWrite = min(
      cacheWrite,
      max(0, (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0)
    )
    let context = input + cacheWrite + cacheRead

    // Most of the context written again = the cache had expired, so the whole history was paid at full price.
    let recache = cacheWrite >= 50_000 && cacheWrite > context / 2 ? cacheWrite : 0
    let cost = (
      Double(input) * inputPrice +
      Double(output) * outputPrice +
      Double(cacheWrite - oneHourWrite) * inputPrice * 1.25 +
      Double(oneHourWrite) * inputPrice * 2 +
      Double(cacheRead) * cacheReadPrice
    ) / 1_000_000

    return TokenMetrics(
      cacheWriteTokens: cacheWrite,
      totalTokens: input + cacheWrite + output,
      contextTokens: context,
      cost: cost,
      recacheTokens: recache
    )
  }

  public static func completeLines(in data: Data) -> (lines: [Data], consumedBytes: Int) {
    guard let lastNewline = data.lastIndex(of: 10) else { return ([], 0) }
    let completeData = data[..<lastNewline]
    let lines = completeData.split(separator: 10).map { Data($0) }
    return (lines, data.distance(from: data.startIndex, to: lastNewline) + 1)
  }
}
