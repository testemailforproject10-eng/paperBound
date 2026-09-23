//
//  PresetReachabilityTests.swift
//  PaperboundTests
//
//  A preset that exists in the model but appears in no picker is not a feature.
//
//  The themed environments shipped defined, rendering and covered by tests, and
//  were still unreachable: both pickers listed `presets`, which is the plain six.
//  The only way to open a stone tablet was a debug launch argument, and once the
//  reader changed any setting there was no way back to it. These assertions are
//  about reachability rather than correctness.
//

import XCTest
@testable import Paperbound

final class PresetReachabilityTests: XCTestCase {

    /// The list the pickers actually iterate has to contain everything.
    func testAllPresetsContainsEveryPlainAndThemedEnvironment() {
        let all = Set(ReadingEnvironment.allPresets.map(\.id))

        for preset in ReadingEnvironment.presets {
            XCTAssertTrue(
                all.contains(preset.id),
                "\(preset.name) is not in allPresets and so reaches no picker"
            )
        }
        for preset in ReadingEnvironment.themedPresets {
            XCTAssertTrue(
                all.contains(preset.id),
                "\(preset.name) is not in allPresets and so reaches no picker"
            )
        }
        XCTAssertEqual(
            all.count,
            ReadingEnvironment.presets.count + ReadingEnvironment.themedPresets.count
        )
    }

    /// Ids are what selection highlighting compares, so a duplicate would make
    /// two presets appear selected at once.
    func testPresetIdentifiersAreUnique() {
        let ids = ReadingEnvironment.allPresets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate preset id in allPresets")
    }

    /// The editor turns a preset into "Custom" by testing these two prefixes.
    /// A preset id outside them would keep its name while its settings drifted,
    /// so the header would claim a preset the page no longer matches.
    func testEveryPresetIdUsesAPrefixTheEditorRecognises() {
        for preset in ReadingEnvironment.allPresets {
            XCTAssertTrue(
                preset.id.hasPrefix("preset.") || preset.id.hasPrefix("theme."),
                "\(preset.id) is neither preset.* nor theme.*, so editing it would not clear its name"
            )
        }
    }

    /// Two presets that differ in no visible way are two entries that do the
    /// same thing, which is a picker bug rather than a rendering one.
    func testEveryPresetIsVisuallyDistinctFromTheOthers() {
        let identities = ReadingEnvironment.allPresets.map(\.renderIdentity)
        XCTAssertEqual(
            Set(identities).count,
            identities.count,
            "two presets render identically"
        )
    }

    /// Every themed preset names itself. An empty or duplicated label is what
    /// the picker draws under the swatch.
    func testEveryPresetHasADistinctNonEmptyName() {
        let names = ReadingEnvironment.allPresets.map(\.name)
        for name in names {
            XCTAssertFalse(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertEqual(Set(names).count, names.count, "two presets share a name")
    }
}
