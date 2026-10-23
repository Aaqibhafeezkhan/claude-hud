import Foundation
import XCTest
@testable import HUDCore

final class TokenMathTests: XCTestCase {
  private let prices = (input: 3.0, output: 15.0, cacheRead: 0.3)

  private var fixtureLines: [String] {
    let url = Bundle.module.url(forResource: "token-usage", withExtension: "jsonl", subdirectory: "Fixtures")!
    return try! String(contentsOf: url, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map(String.init)
  }

  private func metrics(_ index: Int) -> TokenMetrics {
    TokenMath.parse(
      line: fixtureLines[index],
      inputPrice: prices.input,
      outputPrice: prices.output,
      cacheReadPrice: prices.cacheRead
    )!
  }

  func testNormalMessageCountsTokensAndCalculatesCost() {
    let result = metrics(0)
    XCTAssertEqual(result.totalTokens, 160)
    XCTAssertEqual(result.contextTokens, 140)
    XCTAssertEqual(result.cost, (100 * 3.0 + 20 * 15.0 + 40 * 3.0 * 1.25) / 1_000_000, accuracy: 1e-12)
    XCTAssertEqual(result.recacheTokens, 0)
  }

  func testFiveMinuteCacheWriteUsesOnePointTwoFiveMultiplier() {
    let result = metrics(1)
    XCTAssertEqual(result.cacheWriteTokens, 100)
    XCTAssertEqual(result.cost, (100 * 3.0 * 1.25) / 1_000_000, accuracy: 1e-12)
  }

  func testOneHourCacheWriteUsesTwoTimesInputPrice() {
    let result = metrics(2)
    XCTAssertEqual(result.cost, (100 * 3.0 * 2) / 1_000_000, accuracy: 1e-12)
  }

  func testCacheReadUsesCacheReadPrice() {
    let result = metrics(3)
    XCTAssertEqual(result.cost, (500 * 0.3) / 1_000_000, accuracy: 1e-12)
  }

  func testExpiredCacheDetectsLargeContextWrittenAgain() {
    let result = metrics(4)
    XCTAssertEqual(result.cacheWriteTokens, 60_000)
    XCTAssertEqual(result.recacheTokens, 60_000)
  }

  func testNonAssistantOrMalformedLinesAreIgnored() {
    XCTAssertNil(TokenMath.parse(line: #"{ "type":"user" }"#, inputPrice: 3, outputPrice: 15, cacheReadPrice: 0.3))
    XCTAssertNil(TokenMath.parse(line: "{broken", inputPrice: 3, outputPrice: 15, cacheReadPrice: 0.3))
  }

  func testTruncatedFinalLineIsNotConsumedUntilNewlineArrives() {
    let partial = Data(#"{"type":"assistant"}"#.utf8)
    let firstRead = TokenMath.completeLines(in: partial)
    XCTAssertTrue(firstRead.lines.isEmpty)
    XCTAssertEqual(firstRead.consumedBytes, 0)

    let completed = TokenMath.completeLines(in: partial + Data([10]))
    XCTAssertEqual(completed.lines, [partial])
    XCTAssertEqual(completed.consumedBytes, partial.count + 1)
  }
}
