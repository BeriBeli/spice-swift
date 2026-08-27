import Foundation

/// Immutable, Sendable ownership for received wire bytes.
///
/// `Span` values borrowed from this owner are deliberately scoped to a
/// synchronous closure. Only `OwnedBytes` and checked `WireSlice` ranges may
/// cross an actor boundary or suspension point.
package struct OwnedBytes: Sendable, Equatable {
    fileprivate final class Storage: @unchecked Sendable {
        let data: Data

        init(_ data: consuming Data) {
            self.data = data
        }
    }

    fileprivate let storage: Storage

    package init(_ data: consuming Data) {
        storage = Storage(data)
    }

    package var count: Int { storage.data.count }
    package var isEmpty: Bool { storage.data.isEmpty }

    /// Package-only lifetime probe for ownership diagnostics and tests.
    /// The token must not escape into production protocol models.
    package var ownerLifetimeToken: AnyObject { storage }

    /// Explicit Foundation boundary. The complete owner can reuse `Data`'s
    /// value storage; sliced boundaries intentionally materialize their range.
    package var data: Data { storage.data }

    package var wholeSlice: WireSlice {
        // The range is constructed from this owner's trusted size.
        WireSlice(uncheckedOwner: self, range: 0..<count)
    }

    package func slice(_ range: Range<Int>) throws(WireError) -> WireSlice {
        try WireSlice(owner: self, range: range)
    }

    package func withSpan<Result, Failure: Error>(
        _ body: (borrowing Span<UInt8>) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(storage.data.span)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wholeSlice == rhs.wholeSlice
    }
}

/// A checked half-open range into one immutable byte owner.
package struct WireSlice: Sendable, Equatable {
    package let owner: OwnedBytes
    package let range: Range<Int>

    package init(owner: OwnedBytes, range: Range<Int>) throws(WireError) {
        guard range.lowerBound >= 0 else {
            throw .invalidOffset(UInt64(max(range.lowerBound, 0)))
        }
        guard range.upperBound >= range.lowerBound else {
            throw .invalidSize(range.upperBound - range.lowerBound)
        }
        guard range.upperBound <= owner.count else {
            throw .truncated(
                expected: range.count,
                remaining: max(owner.count - range.lowerBound, 0)
            )
        }
        self.owner = owner
        self.range = range
    }

    fileprivate init(uncheckedOwner owner: OwnedBytes, range: Range<Int>) {
        self.owner = owner
        self.range = range
    }

    package var count: Int { range.count }
    package var isEmpty: Bool { range.isEmpty }
    package var retainedOwnerByteCount: Int { owner.count }

    /// Explicit Foundation boundary for subsystems that still require `Data`.
    package var data: Data {
        guard range != 0..<owner.count else {
            return owner.data
        }
        let data = owner.storage.data
        let lower = data.index(data.startIndex, offsetBy: range.lowerBound)
        let upper = data.index(data.startIndex, offsetBy: range.upperBound)
        return data.subdata(in: lower..<upper)
    }

    package func slice(_ relativeRange: Range<Int>) throws(WireError) -> WireSlice {
        guard relativeRange.lowerBound >= 0 else {
            throw .invalidOffset(UInt64(max(relativeRange.lowerBound, 0)))
        }
        guard relativeRange.upperBound >= relativeRange.lowerBound else {
            throw .invalidSize(relativeRange.upperBound - relativeRange.lowerBound)
        }
        guard relativeRange.upperBound <= count else {
            throw .truncated(
                expected: relativeRange.count,
                remaining: max(count - relativeRange.lowerBound, 0)
            )
        }
        let (lower, lowerOverflow) = range.lowerBound.addingReportingOverflow(
            relativeRange.lowerBound
        )
        let (upper, upperOverflow) = range.lowerBound.addingReportingOverflow(
            relativeRange.upperBound
        )
        guard !lowerOverflow, !upperOverflow else {
            throw .integerOverflow
        }
        return WireSlice(uncheckedOwner: owner, range: lower..<upper)
    }

    package func withSpan<Result, Failure: Error>(
        _ body: (borrowing Span<UInt8>) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(owner.storage.data.span.extracting(range))
    }

    package func sharesOwner(with other: WireSlice) -> Bool {
        owner.storage === other.owner.storage
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.sharesOwner(with: rhs), lhs.range == rhs.range {
            return true
        }
        guard lhs.count == rhs.count else {
            return false
        }
        return lhs.withSpan { lhsBytes in
            rhs.withSpan { rhsBytes in
                for index in 0..<lhsBytes.count where lhsBytes[index] != rhsBytes[index] {
                    return false
                }
                return true
            }
        }
    }
}

package func == (lhs: WireSlice, rhs: Data) -> Bool {
    lhs == OwnedBytes(rhs).wholeSlice
}

package func == (lhs: Data, rhs: WireSlice) -> Bool {
    OwnedBytes(lhs).wholeSlice == rhs
}
