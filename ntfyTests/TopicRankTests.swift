import XCTest
@testable import ntfy

final class TopicRankTests: XCTestCase {
    func testInsertingIntoEmptyListReturnsZero() {
        XCTAssertEqual(TopicRank.rank(insertingBefore: 0, in: []), 0)
    }

    func testInsertingAtFrontIsLessThanCurrentFirst() {
        let rank = TopicRank.rank(insertingBefore: 0, in: [5, 10, 15])
        XCTAssertEqual(rank, 4)
    }

    func testInsertingAtEndIsGreaterThanCurrentLast() {
        let rank = TopicRank.rank(insertingBefore: 3, in: [5, 10, 15])
        XCTAssertEqual(rank, 16)
    }

    func testInsertingInTheMiddleIsTheMidpointOfItsNeighbors() {
        let rank = TopicRank.rank(insertingBefore: 1, in: [5, 10, 15])
        XCTAssertEqual(rank, 7.5)
    }

    func testDestinationIndexBeyondBoundsClampsToEnd() {
        let rank = TopicRank.rank(insertingBefore: 99, in: [5, 10, 15])
        XCTAssertEqual(rank, 16)
    }
}
