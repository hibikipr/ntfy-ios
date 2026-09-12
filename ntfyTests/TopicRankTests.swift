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

    func testInsertingBetweenEqualNeighborsBreaksTheTieInsteadOfReproducingIt() {
        let rank = TopicRank.rank(insertingBefore: 1, in: [5, 5, 15])
        // The naive midpoint of two equal neighbors would just be 5 again — indistinguishable
        // from the tie, making the drag a silent no-op. The result must land strictly below the
        // upper (and equal lower) neighbor instead, so the moved item can be told apart from it.
        XCTAssertNotEqual(rank, 5)
        XCTAssertLessThan(rank, 5)
        XCTAssertEqual(rank, 5 - 0.000001, accuracy: 0.0000001)
    }

    func testInsertingBeforeIndexZeroInSingleItemListIsLessThanTheItem() {
        let rank = TopicRank.rank(insertingBefore: 0, in: [5])
        XCTAssertEqual(rank, 4)
    }

    func testInsertingAtEndOfSingleItemListIsGreaterThanTheItem() {
        let rank = TopicRank.rank(insertingBefore: 1, in: [5])
        XCTAssertEqual(rank, 6)
    }
}
