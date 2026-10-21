import Testing
import Foundation
@testable import MajiksMusicStudio

// A SCHEDULED publish is not a publish, and the queue has to say which it was.
//
// The journey is "sign in as a publisher, publish a finished track, see it on
// the site". The metadata sheet offers a schedule and states the consequence
// plainly (`MetadataEditSheet.swift:388`):
//
//     "Track will be created with scheduled visibility and auto-publish at this time"
//
// So the app KNOWS the track is not going live now. It then reported it exactly
// like one that did: `status = .published(...)`, `statusText` "Published", a
// green filled tick, and a "view on the site" button built from the slug. Server
// side the row is `visibility = 'scheduled'`, `published_at = null` — so the
// owner schedules a track, reads "Published", clicks through, and finds nothing
// there.
//
// That is question 2 of this audit — does it do what it says — and the answer
// was no. Everything below asserts on what the USER is shown, never on a flag.

@Suite("Scheduled publishes are reported as scheduled, not as published")
struct PublisherScheduledStatusTests {

    /// A fixed, far-future instant so the formatted text is stable and this
    /// suite can never start failing because a date drifted into the past.
    private static let scheduled = Date(timeIntervalSince1970: 1_800_000_000)

    private static func live() -> PublishStatus {
        .published(trackId: "t1", slug: "my-track", scheduledAt: nil)
    }

    private static func pending() -> PublishStatus {
        .published(trackId: "t1", slug: "my-track", scheduledAt: scheduled)
    }

    // MARK: - What the badge says

    @Test("a scheduled track does not claim to be published")
    func scheduledDoesNotSayPublished() {
        let text = Self.pending().statusText
        #expect(
            text != "Published",
            """
            a track that is not on the site yet reported itself as "Published" — \
            the exact claim the journey is about
            """)
        #expect(
            text.localizedCaseInsensitiveContains("scheduled"),
            "the badge does not say the track is scheduled: \(text)")
    }

    @Test("the badge names WHEN, because a date is the whole point of scheduling")
    func scheduledNamesTheDate() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        #expect(
            Self.pending().statusText.contains(formatter.string(from: Self.scheduled)),
            """
            the badge says it is scheduled but not for when, which leaves the owner \
            with no way to know whether to wait ten minutes or a week
            """)
    }

    @Test("an immediate publish is still reported as published")
    func liveStillSaysPublished() {
        #expect(
            Self.live().statusText == "Published",
            "the ordinary publish path changed meaning; this fix must only affect scheduled tracks")
    }

    // MARK: - The link

    @Test("a scheduled track offers no link, because there is no page yet")
    func scheduledHasNoLink() {
        #expect(
            Self.pending().trackURL == nil,
            """
            the queue offered a public URL for a track that is not live. A link that \
            404s reads as "the publish broke", which is a worse lie than saying nothing
            """)
    }

    @Test("a live track still links to its page")
    func liveHasALink() {
        #expect(
            Self.live().trackURL == "https://majiks.online/track/my-track",
            "the working case regressed — the link is how a person gets from the app to the site")
    }

    // MARK: - The two questions are kept apart

    @Test("scheduled counts as published for the QUEUE but not for the SITE")
    func theTwoNotionsAreDistinct() {
        // `isPublished` means "this no longer needs publishing" — the upload
        // really did happen, so the queue must not offer to publish it again.
        #expect(
            Self.pending().isPublished,
            """
            a scheduled track stopped counting as published, so the queue would offer \
            to upload it a second time and create a duplicate
            """)
        // `isLiveOnSite` means "a person can go and look at it". Conflating the
        // two is the whole defect.
        #expect(
            !Self.pending().isLiveOnSite,
            "a scheduled track claims to be live on the site")
        #expect(
            Self.live().isLiveOnSite,
            "a genuinely published track does not count as live")
    }

    @Test("the two outcomes are not the same status value")
    func scheduledAndLiveAreNotEqual() {
        #expect(
            Self.live() != Self.pending(),
            """
            a scheduled and a live publish compare EQUAL, so no view could ever draw \
            them differently however carefully it tried
            """)
    }

    // MARK: - The feed line
    //
    // Everything above can be right while `publishTrack` still constructs the
    // status with `scheduledAt: nil` and throws the schedule away on the way in
    // — the survivor shape this repo keeps shipping. This reads the store's
    // source, which is the only way to see that call without a signed-in
    // account and a live server.

    /// Read through `JourneyAuditSource`, which strips comments first.
    ///
    /// A raw `contains` over this file would be answerable by the very comment
    /// that explains the fix — `PublisherStore` carries a note beside the call
    /// describing what it passes and why. A concurrent lane shipped three
    /// guards tonight that were each satisfied by their own warning prose, and
    /// this lane already found one guard of its own satisfied by a function
    /// declaration. Comment-stripped, this asserts the CODE does it.
    @Test("the store carries the candidate's schedule into the status it sets")
    func theStoreFeedsTheScheduleThrough() throws {
        let text = try JourneyAuditSource.source("Publisher/PublisherStore.swift")

        #expect(
            JourneyAuditSource.mentions(of: "scheduledAt: candidate.scheduledAt", in: text) > 0,
            """
            publishTrack no longer passes the candidate's schedule into .published, so \
            every scheduled track is recorded as live again and the badge, the icon and \
            the link all go back to lying together
            """)
    }
}
