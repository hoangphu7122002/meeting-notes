import AppKit
import MeetingNotesCore
import MeetingNotesUI
import SwiftUI
import Testing

@Suite("Status icon images")
@MainActor
struct StatusIconImageTests {
    @Test func idleGlyphIsAnEighteenPointTemplate() throws {
        let image = try #require(StatusIconImage.make(.idle))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "Meeting Notes")
    }

    @Test func recordingAndPausedKeepTheirColor() throws {
        for icon in [StatusIcon.recording, .paused] {
            let image = try #require(StatusIconImage.make(icon))
            #expect(!image.isTemplate, "\(icon)")
            #expect(image.accessibilityDescription?.contains("Meeting Notes") == true)
        }
    }

    @Test func symbolStatesStayTemplates() throws {
        for icon in [StatusIcon.attention, .busy, .processing, .ready, .error] {
            let image = try #require(StatusIconImage.make(icon))
            #expect(image.isTemplate, "\(icon)")
        }
    }

    @Test func glyphStaysInsideItsGrid() {
        let bounds = BrandGlyph().path(in: CGRect(x: 0, y: 0, width: 18, height: 18)).boundingRect
        #expect(bounds.minX >= 0 && bounds.minY >= 0 && bounds.maxX <= 18 && bounds.maxY <= 18)
    }
}
