import XCTest
@testable import Paperbound

final class PageEffectTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 100)
    let surfaces = [CGRect(x:0,y:0,width:320,height:480), CGRect(x:340,y:0,width:320,height:480)]
    func controller(_ effect: PageEffect, seed: UInt64 = 42) -> PageEffectController {
        PageEffectController(effect: effect, seed: seed, surfaces: surfaces, startedAt: start)
    }

    func testMigrationPrecedenceAndRenderIdentity() throws {
        let plain = ReadingEnvironment.cleanPaper
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String:Any])
        legacy.removeValue(forKey: "pageEffect")
        legacy["footstepsEnabled"] = true
        func decode() throws -> ReadingEnvironment {
            try JSONDecoder().decode(ReadingEnvironment.self, from: JSONSerialization.data(withJSONObject: legacy))
        }
        XCTAssertEqual(try decode().pageEffect, .footsteps)
        legacy.removeValue(forKey: "footstepsEnabled")
        XCTAssertEqual(try decode().pageEffect, .none)
        legacy["footstepsEnabled"] = true
        legacy["pageEffect"] = "none"
        XCTAssertEqual(try decode().pageEffect, .none)
        legacy["pageEffect"] = "future-effect"
        XCTAssertEqual(try decode().pageEffect, .none)
        for effect in PageEffect.allCases {
            var env = plain; env.pageEffect = effect
            XCTAssertEqual(env.effectsOnly.pageEffect, effect)
            XCTAssertEqual(env.renderIdentity, plain.renderIdentity)
            XCTAssertEqual(try JSONDecoder().decode(ReadingEnvironment.self, from: JSONEncoder().encode(env)).pageEffect, effect)
            XCTAssertEqual(env.footstepsEnabled, effect == .footsteps)
        }
    }

    func testAllEffectsAreDeterministicBoundedAndAdvance() {
        for effect in PageEffect.allCases where effect.hasSpriteArtwork {
            let a = controller(effect), b = controller(effect), c = controller(effect, seed: 177)
            var samples: [[PageEffectSprite]] = [], other: [[PageEffectSprite]] = []
            for step in 0..<600 {
                let elapsed = Double(step)/10
                a.prepare(through: elapsed+24, discardingBefore: elapsed-1)
                b.prepare(through: elapsed+24, discardingBefore: elapsed-1)
                c.prepare(through: elapsed+24, discardingBefore: elapsed-1)
                let date = start.addingTimeInterval(elapsed)
                let sprites = a.sprites(at: date)
                XCTAssertEqual(sprites,b.sprites(at:date),effect.rawValue)
                XCTAssertLessThanOrEqual(sprites.count,32)
                XCTAssertLessThan(a.events.count,400,"Planning must not grow without bound")
                XCTAssertTrue(sprites.allSatisfy { $0.opacity >= 0 && $0.opacity <= 0.65 && $0.center.x.isFinite && $0.center.y.isFinite })
                samples.append(sprites); other.append(c.sprites(at:date))
            }
            XCTAssertTrue(samples.contains { !$0.isEmpty }, effect.rawValue)
            XCTAssertNotEqual(samples,other,effect.rawValue)
            XCTAssertNotEqual(samples[10],samples[20],effect.rawValue)
        }
    }

    func testPauseResumesWithoutTimeJumpAndInjectedClock() {
        var now = start
        let c = PageEffectController(effect:.paperMessengers,seed:42,surfaces:surfaces,startedAt:start,
                                     clock:PageEffectClock(now:{ now }))
        now = start.addingTimeInterval(1)
        c.pause()
        let before = c.sprites()
        now = start.addingTimeInterval(40)
        XCTAssertEqual(c.sprites(),before)
        c.resume()
        XCTAssertEqual(c.sprites(),before)
        now = now.addingTimeInterval(0.5)
        XCTAssertNotEqual(c.sprites(),before)
    }

    func testCrossingsUseRealHorizontalAndStackedSurfaces() {
        for rects in [surfaces,[CGRect(x:0,y:0,width:320,height:450),CGRect(x:0,y:470,width:320,height:450)]] {
            let c = PageEffectController(effect:.paperMessengers,seed:1,surfaces:rects,startedAt:start)
            let first = c.events[0]
            let viewport = rects.reduce(CGRect.null) { $0.union($1) }
            XCTAssertFalse(viewport.contains(first.from))
            XCTAssertFalse(viewport.contains(first.to))
            XCTAssertTrue(first.route.samples.contains { sample in rects.contains { $0.contains(sample.point) } })
            let single = PageEffectController(effect:.paperMessengers,seed:1,surfaces:[rects[0]],startedAt:start)
            XCTAssertFalse(rects[0].contains(single.events[0].to))
        }
    }

    func testPersistentActorsNeverSwapPosesOrTeleportBetweenJourneys() {
        for effect in [PageEffect.marginCreatures,.enchantedButterflies,.wanderingWisps,.wonderlandCards,.littleHearthSpirit] {
            let c = controller(effect)
            c.prepare(through:120)
            for e in c.events where e.persistent && !e.firstAppearance && e.start > 0 {
                let before = c.sprites(at:start.addingTimeInterval(e.start-0.0001)).first { $0.actorID == e.actorID }
                let after = c.sprites(at:start.addingTimeInterval(e.start+0.0001)).first { $0.actorID == e.actorID }
                guard let before, let after else { XCTFail("Missing continuous actor \(effect)"); continue }
                XCTAssertEqual(before.frame,after.frame)
                XCTAssertLessThan(hypot(before.center.x-after.center.x,before.center.y-after.center.y),0.05)
                XCTAssertEqual(before.angle,after.angle,accuracy:0.005)
                XCTAssertEqual(before.size.width,after.size.width,accuracy:0.01)
                XCTAssertEqual(before.opacity,after.opacity,accuracy:0.001)
            }
            let frames = Set((0..<600).flatMap { step in
                c.sprites(at:start.addingTimeInterval(Double(step)/30)).filter { $0.rig != .whole }.map(\.frame)
            })
            XCTAssertEqual(frames.count,1,"The same registered drawing is used throughout a character's performance")
        }
    }

    func testWingAndStrideAnimationAreContinuousAtDisplayCadence() {
        let c = controller(.enchantedButterflies)
        let moving = c.events[0].movingFor
        var previous: Double?
        var distinct = Set<Int>()
        for i in 30..<120 {
            let sprite = c.sprites(at:start.addingTimeInterval(Double(i)/30))[0]
            let value = PageEffectMotion.wingScale(phase:sprite.phase,activity:sprite.activity)
            if let previous { XCTAssertLessThan(abs(previous-value),0.34) }
            distinct.insert(Int(value*1000))
            previous = value
        }
        XCTAssertGreaterThan(distinct.count,15,"Wingbeats must have intermediate shapes, not two or three poses")
        XCTAssertGreaterThan(moving,3)
        for effect in [PageEffect.marginCreatures,.wonderlandCards] {
            let c = controller(effect)
            for event in c.events {
                XCTAssertLessThanOrEqual(event.route.length/event.movingFor,58.01)
            }
        }
    }

    func testRoutesExplorePageInteriorsAndKeepArcLengthSpeedUniform() {
        let c = controller(.marginCreatures)
        XCTAssertTrue(c.events.contains { e in e.route.samples.contains { sample in
            surfaces.contains { $0.insetBy(dx:60,dy:80).contains(sample.point) }
        } })
        let route = PageEffectRoute(points:[CGPoint(x:0,y:0),CGPoint(x:140,y:50),CGPoint(x:30,y:220),CGPoint(x:300,y:250)])
        var last = route.at(distance:0).point
        for distance in stride(from:2.0,through:route.length,by:2) {
            let next = route.at(distance:distance).point
            XCTAssertEqual(hypot(next.x-last.x,next.y-last.y),2,accuracy:0.05)
            last = next
        }
    }

    func testReadinessRejectsSupersededVisitsAndRenderIdentities() {
        let id = UUID()
        var visit = PageEffectVisit(unit:0,visitID:id,pageRenderTokens:["a":"render-a","b":"render-b"])
        visit.setVisibleFraction(0.04,at:start)
        XCTAssertFalse(visit.paperReady(pageIdentity:"a",renderToken:"stale",visitID:id,at:start))
        XCTAssertFalse(visit.paperReady(pageIdentity:"a",renderToken:"render-a",visitID:UUID(),at:start))
        XCTAssertTrue(visit.paperReady(pageIdentity:"a",renderToken:"render-a",visitID:id,at:start))
        XCTAssertTrue(visit.paperReady(pageIdentity:"b",renderToken:"render-b",visitID:id,at:start))
        XCTAssertNil(visit.startedAt)
        visit.setVisibleFraction(0.05,at:start)
        XCTAssertEqual(visit.startedAt,start)
    }

    func testFeetPlantThenLiftAndRecoverWithoutSliding() {
        let cycle = 17.5
        let contacts = stride(from:0.0,through:0.59,by:0.01).map {
            PageEffectMotion.footContact(distance:$0*cycle,cycle:cycle,offset:0)
        }
        for foot in contacts {
            XCTAssertEqual(foot.distance,cycle*0.3,accuracy:0.000001)
            XCTAssertEqual(foot.lift,0)
        }
        let swing = PageEffectMotion.footContact(distance:cycle*0.8,cycle:cycle,offset:0)
        XCTAssertGreaterThan(swing.lift,0.99)
        let before = PageEffectMotion.footContact(distance:cycle-0.00001,cycle:cycle,offset:0)
        let after = PageEffectMotion.footContact(distance:cycle+0.00001,cycle:cycle,offset:0)
        XCTAssertEqual(before.distance,after.distance,accuracy:0.0001)
        XCTAssertEqual(before.lift,after.lift,accuracy:0.0001)
        let c = controller(.wonderlandCards)
        for event in c.events { XCTAssertLessThanOrEqual(event.route.length/event.movingFor,29.01) }
        // Actual page-space stance remains stationary as the torso advances.
        var pinnedPairs = 0
        for i in 30..<120 {
            let a = c.sprites(at:start.addingTimeInterval(Double(i)/30))[0]
            let b = c.sprites(at:start.addingTimeInterval(Double(i+1)/30))[0]
            for side in 0..<2 {
                let worldA = CGPoint(x:a.center.x+a.feet[side].x*a.size.width,y:a.center.y+a.feet[side].y*a.size.height)
                let worldB = CGPoint(x:b.center.x+b.feet[side].x*b.size.width,y:b.center.y+b.feet[side].y*b.size.height)
                if hypot(worldA.x-worldB.x,worldA.y-worldB.y) < 0.001 { pinnedPairs += 1 }
            }
        }
        XCTAssertGreaterThan(pinnedPairs,50)
    }

    func testVariedArrivalsPopulationsAndQuietSpells() {
        for effect in [PageEffect.fallingRosePetals,.winterMargins,.paperMessengers,.floatingLanterns] {
            let c = controller(effect)
            XCTAssertTrue(c.sprites(at:start).isEmpty,"No prefilled population")
            var counts = Set<Int>()
            for second in 1..<300 {
                c.prepare(through:Double(second)+24,discardingBefore:Double(second)-1)
                let sprites = c.sprites(at:start.addingTimeInterval(Double(second)))
                let visible = sprites.filter { sprite in
                    surfaces.contains { $0.contains(sprite.center) } && sprite.opacity > 0.02
                }
                counts.insert(visible.count)
                XCTAssertLessThanOrEqual(c.events.filter { Double(second) >= $0.start && Double(second) < $0.start+$0.duration }.count,32,
                    "Admission must not rely on dropping already visible sprites")
            }
            XCTAssertGreaterThan(counts.count,3,effect.rawValue)
            XCTAssertTrue(counts.contains(0),"Allow a genuinely empty quiet spell")
        }
        var populations = Set<Int>()
        for seed in 0..<20 {
            let c = controller(.marginCreatures,seed:UInt64(seed))
            populations.insert(c.events.filter { $0.firstAppearance && $0.actorID < 100 }.count)
        }
        XCTAssertGreaterThan(populations.count,2)
    }

    func testActorsEnterFromBeyondViewportMeetThenFollowOut() {
        let viewport = CGRect(x:-40,y:-50,width:760,height:580)
        for effect in [PageEffect.marginCreatures,.wonderlandCards,.enchantedButterflies,.wanderingWisps,.littleHearthSpirit] {
            let c = PageEffectController(effect:effect,seed:42,surfaces:surfaces,startedAt:start,viewport:viewport)
            for entrance in c.events where entrance.firstAppearance {
                XCTAssertFalse(viewport.insetBy(dx:-entrance.length/2,dy:-entrance.length/2).contains(entrance.from))
                let departure = c.events.first { $0.actorID == entrance.actorID && !$0.firstAppearance }
                guard let departure else {
                    XCTAssertFalse(viewport.contains(entrance.to),"An ignoring visitor exits on its uninterrupted route")
                    XCTAssertEqual(entrance.duration,entrance.movingFor)
                    XCTAssertTrue(entrance.socialCues.isEmpty)
                    continue
                }
                XCTAssertEqual(entrance.to,departure.from)
                XCTAssertEqual(entrance.start+entrance.duration,departure.start,accuracy:0.0001)
                XCTAssertFalse(viewport.contains(departure.to))
                XCTAssertGreaterThan(entrance.duration,entrance.movingFor)
            }
            for follower in c.events where follower.behavior == .following {
                XCTAssertNotNil(follower.companionID)
                XCTAssertTrue(c.events.contains { $0.actorID == follower.companionID && !$0.firstAppearance && $0.start < follower.start })
            }
        }
    }

    func testPetalsUsePreparedGravityDragAndLargerVariedSizes() {
        let c = controller(.fallingRosePetals)
        XCTAssertTrue(c.events.allSatisfy { $0.length >= 25 && $0.length <= 39 && $0.timeSampled })
        let e = c.events[0]
        XCTAssertFalse(c.viewport.contains(e.from))
        XCTAssertFalse(c.viewport.contains(e.to))
        let points = e.route.samples.map(\.point)
        XCTAssertTrue(zip(points,points.dropFirst()).allSatisfy { $0.1.y > $0.0.y })
        let speeds = zip(points,points.dropFirst()).map { hypot($0.1.x-$0.0.x,$0.1.y-$0.0.y)*30 }
        XCTAssertGreaterThan((speeds.max() ?? 0)-(speeds.min() ?? 0),10)
        let replay = controller(.fallingRosePetals)
        XCTAssertEqual(points,replay.events[0].route.samples.map(\.point))
    }

    func testTallSpreadAdmissionNeverHidesLiveParticles() {
        let rects = [CGRect(x:0,y:0,width:650,height:900),CGRect(x:0,y:930,width:650,height:900)]
        for seed in 0..<6 {
            let c = PageEffectController(effect:.winterMargins,seed:UInt64(seed),surfaces:rects,startedAt:start)
            for second in stride(from:0,through:180,by:2) {
                let time = Double(second)
                c.prepare(through:time+24,discardingBefore:time-1)
                let active = c.events.filter { time >= $0.start && time < $0.start+$0.duration }
                XCTAssertLessThanOrEqual(active.count,32)
                XCTAssertEqual(c.sprites(at:start.addingTimeInterval(time)).count,active.count)
                XCTAssertTrue(active.allSatisfy { !c.viewport.contains($0.from) && !c.viewport.contains($0.to) })
            }
        }
    }

    func testFlameShapeChangesContinuouslyAndTonguesAreIndependent() {
        var previous = PageEffectFlameDrawing.tongue(time:0,lane:0)
        var minY = previous.tip.y, maxY = previous.tip.y
        for frame in 1...300 {
            let flame = PageEffectFlameDrawing.tongue(time:Double(frame)/30,lane:0)
            XCTAssertLessThan(hypot(flame.tip.x-previous.tip.x,flame.tip.y-previous.tip.y),0.06)
            XCTAssertNotEqual(flame,PageEffectFlameDrawing.tongue(time:Double(frame)/30,lane:1))
            minY = min(minY,flame.tip.y); maxY = max(maxY,flame.tip.y)
            previous = flame
        }
        XCTAssertGreaterThan(maxY-minY,0.25,"Flame must change its outline, not bob an image")
    }

    func testEncountersVaryParticipationRepliesAndIndependentDepartures() {
        var stoppingCounts = Set<Int>(), kinds = Set<String>(), signatures = Set<String>()
        var unanswered = 0, mixed = 0, earlyDepartures = 0
        for seed in 0..<40 {
            let c = controller(.marginCreatures,seed:UInt64(seed))
            let entries = c.events.filter { $0.firstAppearance && $0.actorID < 100 }
            let stopping = entries.filter { $0.duration > $0.movingFor }
            let passing = entries.filter { $0.duration == $0.movingFor }
            stoppingCounts.insert(stopping.count)
            if !passing.isEmpty { mixed += 1 }
            if stopping.count == 1 { unanswered += 1 }
            let cues = stopping.flatMap(\.socialCues)
            signatures.insert(cues.map { "\($0.kind):\($0.targetID ?? -1):\($0.start)" }.joined())
            for passer in passing {
                XCTAssertTrue(passer.socialCues.isEmpty)
                XCTAssertFalse(c.viewport.contains(passer.to))
                // Actual snapshots keep walking through the gathering, rather
                // than merely calling a stationary character an 'ignorer'.
                let time = passer.start+passer.encounterOffset
                let before = c.sprites(at:start.addingTimeInterval(time-0.3)).first { $0.actorID == passer.actorID }!
                let after = c.sprites(at:start.addingTimeInterval(time+0.3)).first { $0.actorID == passer.actorID }!
                XCTAssertGreaterThan(hypot(after.center.x-before.center.x,after.center.y-before.center.y),8)
                XCTAssertEqual(before.speech,0); XCTAssertEqual(after.speech,0)
                XCTAssertGreaterThan(after.activity,0.99)
            }
            for e in stopping {
                XCTAssertTrue(e.socialCues.allSatisfy { $0.start > e.start+e.movingFor+0.7 && $0.end < e.start+e.duration })
                for cue in e.socialCues {
                    kinds.insert(String(describing:cue.kind))
                    let sprite = c.sprites(at:start.addingTimeInterval(cue.start+0.4)).first { $0.actorID == e.actorID }!
                    XCTAssertEqual(sprite.bubble,cue.kind)
                    if cue.kind == .surprise { XCTAssertGreaterThan(sprite.surprise,0.8) }
                    if cue.kind != .nod { XCTAssertGreaterThan(sprite.speech,0.9) }
                    if cue.kind == .surprise || cue.kind == .nod {
                        XCTAssertTrue(stopping.contains { speaker in
                            speaker.actorID == cue.targetID && speaker.socialCues.contains {
                                $0.targetID == e.actorID && $0.start < cue.start && $0.end > cue.start
                            }
                        },"Reactions respond to a nearby speaker, not random punctuation")
                    }
                }
                if e.start+e.duration < (cues.map(\.end).max() ?? 0) { earlyDepartures += 1 }
            }
            let replay = controller(.marginCreatures,seed:UInt64(seed))
            XCTAssertEqual(c.events.flatMap(\.socialCues),replay.events.flatMap(\.socialCues))
        }
        XCTAssertGreaterThan(mixed,10); XCTAssertGreaterThan(unanswered,2)
        XCTAssertGreaterThan(stoppingCounts.count,2); XCTAssertEqual(kinds,["chat","question","surprise","nod"])
        XCTAssertEqual(signatures.count,40); XCTAssertGreaterThan(earlyDepartures,0)
    }

    func testSocialGesturesEaseInAndOutAndPauseWithTheWalker() {
        let c = controller(.marginCreatures,seed:2)
        let cue = c.events.flatMap(\.socialCues)[0]
        XCTAssertEqual(cue.strength(at:cue.start),0)
        XCTAssertEqual(cue.strength(at:cue.end),0)
        XCTAssertLessThan(cue.strength(at:cue.start+0.001),0.001)
        XCTAssertLessThan(cue.strength(at:cue.end-0.001),0.001)
        let date = start.addingTimeInterval(cue.start+0.5)
        let before = c.sprites(at:date)
        c.pause(at:date)
        XCTAssertEqual(before,c.sprites(at:date.addingTimeInterval(20)))
        c.resume(at:date.addingTimeInterval(20))
        XCTAssertEqual(before,c.sprites(at:date.addingTimeInterval(20)))
    }

    func testTurnsAndRestingFeetDoNotPopAtSegmentBoundaries() {
        let c = controller(.marginCreatures,seed:2)
        c.prepare(through:120)
        for e in c.events where e.persistent && !e.firstAppearance {
            let before = c.sprites(at:start.addingTimeInterval(e.start-0.0001)).first { $0.actorID == e.actorID }!
            let after = c.sprites(at:start.addingTimeInterval(e.start+0.0001)).first { $0.actorID == e.actorID }!
            XCTAssertEqual(before.facing,after.facing,accuracy:0.001)
            for side in 0..<2 {
                XCTAssertEqual(before.feet[side].x,after.feet[side].x,accuracy:0.001)
                XCTAssertEqual(before.feet[side].y,after.feet[side].y,accuracy:0.001)
            }
            var previous = after.facing
            for frame in 1...30 {
                let facing = c.sprites(at:start.addingTimeInterval(e.start+Double(frame)/30)).first { $0.actorID == e.actorID }!.facing
                XCTAssertLessThan(abs(facing-previous),0.20)
                previous = facing
            }
        }
    }

    func testFloatingVisitorsHaveSlowerTravel() {
        for effect in [PageEffect.wanderingWisps,.enchantedButterflies] {
            for e in controller(effect).events where e.rig != .whole {
                XCTAssertLessThanOrEqual(e.route.length/e.movingFor,effect == .wanderingWisps ? 36.01 : 44.01)
            }
        }
    }

    func testArtworkCacheSharesDecodedFramesAndReleasesUnusedSets() async throws {
        let cache = PageEffectArtworkCache()
        for effect in PageEffect.allCases where effect.hasSpriteArtwork {
            let first = UUID(), second = UUID()
            let a = try await cache.acquire(effect,owner:first)
            let decodes = await cache.decodeCount
            let b = try await cache.acquire(effect,owner:second)
            let after = await cache.decodeCount
            XCTAssertEqual(decodes,after)
            XCTAssertEqual(a.bytes,b.bytes)
            XCTAssertEqual(a.frames[effect.rawValue]?.count,3)
            let rigBytes = a.parts.values.flatMap { $0 }.reduce(0) { $0 + $1.image.bytesPerRow*$1.image.height }
            XCTAssertGreaterThanOrEqual(a.bytes,rigBytes + 768*256*4)
            XCTAssertLessThanOrEqual(a.bytes,PageEffectArtworkCache.byteLimit)
            await cache.release(first); await cache.release(second); await cache.trim()
            let bytes = await cache.bytes
            XCTAssertEqual(bytes,0)
        }
        do { _ = try await cache.acquire(.none,owner:UUID()); XCTFail("Missing artwork should fail") }
        catch {}
        let canceled = Task { try await Task.sleep(for:.milliseconds(20)); return try await cache.acquire(.winterMargins,owner:UUID()) }
        canceled.cancel()
        do { _ = try await canceled.value; XCTFail("Canceled artwork request should fail") } catch is CancellationError {}
    }
}
