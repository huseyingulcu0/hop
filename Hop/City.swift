import CoreGraphics
import Foundation

// MARK: - Deterministic random numbers (same map on both phones)

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E4B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * unit() }
    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(max(upper, 1))) }
}

// MARK: - Street grid

/// A grid of two-lane streets. Roads run through `xs` (vertical streets) and `ys` (horizontal streets).
/// Cross-section of a street (distance from its center line): lanes 0…70, parking strip 70…100.
struct CityMap {
    let xs: [CGFloat]
    let ys: [CGFloat]

    static let roadHalf: CGFloat = 100
    static let laneOffset: CGFloat = 35
    static let stripOffset: CGFloat = 86
    static let slotLength: CGFloat = 64
    static let slotWidth: CGFloat = 30

    var cols: Int { xs.count }
    var rows: Int { ys.count }
    var nodeCount: Int { cols * rows }

    func node(_ i: Int, _ j: Int) -> Int { j * cols + i }
    func position(of node: Int) -> CGPoint { CGPoint(x: xs[node % cols], y: ys[node / cols]) }

    func neighbors(_ node: Int) -> [Int] {
        let i = node % cols
        let j = node / cols
        var result: [Int] = []
        if i > 0 { result.append(self.node(i - 1, j)) }
        if i < cols - 1 { result.append(self.node(i + 1, j)) }
        if j > 0 { result.append(self.node(i, j - 1)) }
        if j < rows - 1 { result.append(self.node(i, j + 1)) }
        return result
    }

    /// The street segment (between two intersections) closest to a point.
    func nearestSegment(to p: CGPoint) -> (a: Int, b: Int) {
        var bestRow = 0
        for j in 0..<rows where abs(p.y - ys[j]) < abs(p.y - ys[bestRow]) { bestRow = j }
        var bestCol = 0
        for i in 0..<cols where abs(p.x - xs[i]) < abs(p.x - xs[bestCol]) { bestCol = i }
        if abs(p.y - ys[bestRow]) <= abs(p.x - xs[bestCol]) {
            var i0 = 0
            for i in 0..<(cols - 1) where xs[i] <= p.x { i0 = i }
            return (node(i0, bestRow), node(i0 + 1, bestRow))
        } else {
            var j0 = 0
            for j in 0..<(rows - 1) where ys[j] <= p.y { j0 = j }
            return (node(bestCol, j0), node(bestCol, j0 + 1))
        }
    }

    /// Shortest drive along the streets: start point, intersections to pass, target.
    func route(from start: CGPoint, to target: CGPoint) -> [CGPoint] {
        let s = nearestSegment(to: start)
        let t = nearestSegment(to: target)
        if (s.a == t.a && s.b == t.b) || (s.a == t.b && s.b == t.a) {
            return [start, target]
        }
        var dist = [CGFloat](repeating: .greatestFiniteMagnitude, count: nodeCount)
        var previous = [Int](repeating: -1, count: nodeCount)
        var done = [Bool](repeating: false, count: nodeCount)
        dist[s.a] = start.distance(to: position(of: s.a))
        dist[s.b] = start.distance(to: position(of: s.b))
        for _ in 0..<nodeCount {
            var current = -1
            for n in 0..<nodeCount where !done[n] && (current < 0 || dist[n] < dist[current]) { current = n }
            guard current >= 0, dist[current] < .greatestFiniteMagnitude else { break }
            done[current] = true
            for next in neighbors(current) {
                let candidate = dist[current] + position(of: current).distance(to: position(of: next))
                if candidate < dist[next] {
                    dist[next] = candidate
                    previous[next] = current
                }
            }
        }
        let viaA = dist[t.a] + target.distance(to: position(of: t.a))
        let viaB = dist[t.b] + target.distance(to: position(of: t.b))
        var node = viaA <= viaB ? t.a : t.b
        var nodes: [CGPoint] = []
        while node >= 0 {
            nodes.append(position(of: node))
            node = previous[node]
        }
        return [start] + nodes.reversed() + [target]
    }

    /// Shortest drive along the streets from every intersection to `target` (Dijkstra), not
    /// using the street `avoiding` (a bay's own street: arriving along it would be the wrong way,
    /// and a car can't turn back at its end).
    func distances(to target: Int, avoiding: (Int, Int)? = nil) -> [CGFloat] {
        var dist = [CGFloat](repeating: .greatestFiniteMagnitude, count: nodeCount)
        var done = [Bool](repeating: false, count: nodeCount)
        dist[target] = 0
        for _ in 0..<nodeCount {
            var current = -1
            for n in 0..<nodeCount where !done[n] && (current < 0 || dist[n] < dist[current]) { current = n }
            guard current >= 0, dist[current] < .greatestFiniteMagnitude else { break }
            done[current] = true
            for next in neighbors(current) {
                if let street = avoiding, Set([current, next]) == Set([street.0, street.1]) { continue }
                let candidate = dist[current] + position(of: current).distance(to: position(of: next))
                if candidate < dist[next] { dist[next] = candidate }
            }
        }
        return dist
    }

    /// Right-hand lane from intersection `a` to intersection `b`: entry and exit points.
    func lane(from a: Int, to b: Int) -> (start: CGPoint, end: CGPoint, heading: CGFloat) {
        let pa = position(of: a)
        let pb = position(of: b)
        let length = max(pa.distance(to: pb), 1)
        let d = CGPoint(x: (pb.x - pa.x) / length, y: (pb.y - pa.y) / length)
        let n = CGPoint(x: d.y, y: -d.x)
        let inset: CGFloat = 118
        let start = CGPoint(x: pa.x + d.x * inset + n.x * CityMap.laneOffset, y: pa.y + d.y * inset + n.y * CityMap.laneOffset)
        let end = CGPoint(x: pb.x - d.x * inset + n.x * CityMap.laneOffset, y: pb.y - d.y * inset + n.y * CityMap.laneOffset)
        return (start, end, atan2(d.y, d.x))
    }

    // MARK: Traffic lights

    enum Signal {
        case green
        case yellow
        case red
    }

    /// One 18 s cycle per intersection: east-west green 7 s, yellow 1.5 s, all red 0.5 s, then the
    /// same for north-south. Each intersection starts at its own offset so the city is not in sync.
    static let signalCycle: CGFloat = 18

    func signal(at node: Int, horizontal: Bool, time: CGFloat) -> Signal {
        let offset = CGFloat((node * 7919) % 180) / 10
        var t = (time + offset).truncatingRemainder(dividingBy: CityMap.signalCycle)
        if !horizontal { t = (t + CityMap.signalCycle / 2).truncatingRemainder(dividingBy: CityMap.signalCycle) }
        if t < 7 { return .green }
        if t < 8.5 { return .yellow }
        return .red
    }

    /// Height of the pavement (metres) above the road: kerbs and sidewalks stand this high.
    static let kerbTop: CGFloat = 0.15

    /// The ground's height (metres) at a point: the road, or up on the pavement of a block, with
    /// the kerb's rounded edge between (a tyre rolls up it over a few centimetres).
    func kerbHeight(at p: CGPoint) -> CGFloat {
        guard xs.count > 1, ys.count > 1 else { return 0 }
        // The block whose streets surround the point
        var i = 0
        while i < xs.count - 2 && p.x > xs[i + 1] { i += 1 }
        var j = 0
        while j < ys.count - 2 && p.y > ys[j + 1] { j += 1 }
        guard p.x >= xs[i], p.x <= xs[i + 1], p.y >= ys[j], p.y <= ys[j + 1] else { return 0 }
        // The kerb's street face stands 22.5 cm out from the block
        let edge = CityMap.roadHalf - 2.25
        let inside = min(p.x - (xs[i] + edge), (xs[i + 1] - edge) - p.x, p.y - (ys[j] + edge), (ys[j + 1] - edge) - p.y)
        let t = max(0, min(1, (inside + 0.6) / 2.2))
        return CityMap.kerbTop * t * t * (3 - 2 * t)
    }

    /// Building blocks between the streets (inner rectangles, without the street area).
    var blocks: [CGRect] {
        var result: [CGRect] = []
        for i in 0..<(cols - 1) {
            for j in 0..<(rows - 1) {
                result.append(CGRect(x: xs[i] + CityMap.roadHalf, y: ys[j] + CityMap.roadHalf,
                                     width: xs[i + 1] - xs[i] - CityMap.roadHalf * 2,
                                     height: ys[j + 1] - ys[j] - CityMap.roadHalf * 2))
            }
        }
        return result
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }
}

struct BotStart {
    let from: Int
    let to: Int
    let progress: CGFloat
    let tint: Int
}

// MARK: - Spot Wars

/// A free bay on the target street of a city round, with the lane a car drives along to pull
/// into it (the bay is on that lane's right-hand curb).
struct FreeSpot {
    let def: SpotDef
    let entry: Int
    let exit: Int
}

/// A driver hunting for a parking spot: where it starts and the bay it goes for first.
struct HunterStart {
    let start: BotStart
    let spot: Int
}

// MARK: - Rival racers

/// A rival in a car race: its place on the grid, its lane, how fast it drives and its name.
struct RacerStart {
    let position: CGPoint
    let heading: CGFloat
    let from: Int
    let to: Int
    let pace: CGFloat
    let name: String
    let color: Int
}

// MARK: - Taxi

/// What a taxi customer wants on the ride (the tip depends on it).
enum Rider: Int, CaseIterable {
    case hurry       // a time to beat
    case coffee      // a full cup: no hard braking, turning or knocks
    case show        // wants drifts on the way
    case getaway     // the police come after you at once: lose them

    var icon: String {
        switch self {
        case .hurry: return "⏱"
        case .coffee: return "☕"
        case .show: return "🌀"
        case .getaway: return "🚨"
        }
    }
}

/// A taxi round: the customer waving at the kerb by the pick-up bay (free bay 0, which the rival
/// taxis go for), the bay at the destination, and what the customer wants.
struct TaxiDef {
    let customer: CGPoint
    let facing: CGFloat
    let destination: SpotDef
    let rider: Rider
}

// MARK: - City rounds

extension Levels {
    static let cityBase = 100
    static let cityRounds = 5
    static let raceBase = 200
    static let raceRounds = 3
    /// Taxi shifts: three customers.
    static let taxiBase = 300
    static let taxiRounds = 3
    /// An online match (city park race or car race): best of three, the first to finish takes
    /// each round and two rounds win it.
    static let onlineRounds = 3
    static let onlineWinsNeeded = 2
    /// Seconds added to the race time for every crash.
    static let crashPenalty: Double = 3

    /// City streets (park race and car race).
    static func isCity(_ index: Int) -> Bool { index >= cityBase }
    static func isRace(_ index: Int) -> Bool { index >= raceBase && index < taxiBase }
    static func isTaxi(_ index: Int) -> Bool { index >= taxiBase }

    static func level(_ index: Int) -> LevelDef {
        if isTaxi(index) { return city(round: index - taxiBase, race: false, taxi: true) }
        if isRace(index) { return city(round: index - raceBase, race: true) }
        if isCity(index) { return city(round: index - cityBase, race: false) }
        return all[max(0, min(index, all.count - 1))]
    }

    /// The round within its city or race series (0 based).
    static func roundIndex(_ index: Int) -> Int {
        isTaxi(index) ? index - taxiBase : (isRace(index) ? index - raceBase : (isCity(index) ? index - cityBase : index))
    }

    static func isLast(_ index: Int, online: Bool = false) -> Bool {
        if online && isCity(index) { return roundIndex(index) >= onlineRounds - 1 }
        if isTaxi(index) { return index >= taxiBase + taxiRounds - 1 }
        if isRace(index) { return index >= raceBase + raceRounds - 1 }
        if isCity(index) { return index >= cityBase + cityRounds - 1 }
        return index >= all.count - 1
    }

    static func clamp(_ index: Int) -> Int {
        if isTaxi(index) { return min(index, taxiBase + taxiRounds - 1) }
        if isRace(index) { return min(index, raceBase + raceRounds - 1) }
        if isCity(index) { return min(index, cityBase + cityRounds - 1) }
        return max(0, min(index, all.count - 1))
    }

    static func title(_ index: Int, online: Bool = false) -> String {
        if isTaxi(index) { return Strings.customerRound(index - taxiBase + 1, of: online ? onlineRounds : taxiRounds) }
        if isRace(index) { return Strings.raceRound(index - raceBase + 1, of: online ? onlineRounds : raceRounds) }
        if isCity(index) { return Strings.round(index - cityBase + 1, of: online ? onlineRounds : cityRounds) }
        return Strings.level(index + 1, of: all.count)
    }

    /// Race score: time plus a penalty per crash (lower is better).
    static func raceScore(time: Double, crashes: Int) -> Double {
        time + Double(crashes) * crashPenalty
    }

    /// A procedurally generated city with a street grid, parked cars, buildings and traffic.
    /// `race`: a finish line far away and dense traffic instead of a parking target.
    static func city(round: Int, race: Bool, taxi: Bool = false) -> LevelDef {
        var rng = SplitMix64(seed: (UInt64(round + 1) &* 0x2545_F491_4F6C_DD1D) ^ (race ? 0xA5A5_5A5A : 0) ^ (taxi ? 0x7A71_0000 : 0))
        // 7 x 5 streets: 24 blocks (it was 5 x 4, 12 blocks), about 500 x 300 m
        let map = CityMap(xs: [100, 900, 1700, 2500, 3300, 4100, 4900], ys: [100, 800, 1500, 2200, 2900])
        let worldSize = CGSize(width: 5000, height: 3000)

        // Parking slots along every curb that faces a block
        struct Slot { let center: CGPoint; let angle: CGFloat; let segment: Int; let side: Int; let index: Int }
        var slots: [Slot] = []
        var segments: [(a: Int, b: Int, horizontal: Bool, interior: Bool)] = []
        for j in 0..<map.rows {
            for i in 0..<(map.cols - 1) {
                segments.append((map.node(i, j), map.node(i + 1, j), true, j > 0 && j < map.rows - 1))
            }
        }
        for i in 0..<map.cols {
            for j in 0..<(map.rows - 1) {
                segments.append((map.node(i, j), map.node(i, j + 1), false, i > 0 && i < map.cols - 1))
            }
        }
        for (segmentIndex, segment) in segments.enumerated() {
            let pa = map.position(of: segment.a)
            let pb = map.position(of: segment.b)
            let length = pa.distance(to: pb)
            let count = Int((length - 2 * (CityMap.roadHalf + 30)) / CityMap.slotLength)
            for side in [-1, 1] {
                if segment.horizontal {
                    let j = segment.a / map.cols
                    if (side < 0 && j == 0) || (side > 0 && j == map.rows - 1) { continue }
                } else {
                    let i = segment.a % map.cols
                    if (side < 0 && i == 0) || (side > 0 && i == map.cols - 1) { continue }
                }
                for k in 0..<count {
                    let along = CityMap.roadHalf + 30 + CityMap.slotLength * (CGFloat(k) + 0.5)
                    let offset = CGFloat(side) * CityMap.stripOffset
                    let center = segment.horizontal
                        ? CGPoint(x: pa.x + along, y: pa.y + offset)
                        : CGPoint(x: pa.x + offset, y: pa.y + along)
                    slots.append(Slot(center: center, angle: segment.horizontal ? 0 : CGFloat.pi / 2,
                                      segment: segmentIndex, side: side, index: k))
                }
            }
        }

        func midpoint(_ index: Int) -> CGPoint {
            let s = segments[index]
            return CGPoint(x: (map.position(of: s.a).x + map.position(of: s.b).x) / 2,
                           y: (map.position(of: s.a).y + map.position(of: s.b).y) / 2)
        }
        /// How far it is to drive from a street corner to `target` along the streets.
        func driveLength(from node: Int, to target: CGPoint) -> CGFloat {
            let path = map.route(from: map.position(of: node), to: target)
            return zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        }
        func sideBySideStarts(on segmentIndex: Int, towards target: CGPoint?) -> [StartDef] {
            let seg = segments[segmentIndex]
            var fromNode = seg.a
            var toNode = seg.b
            if let target = target {
                // Facing the way the route goes (the corner nearer to the target by road, not as
                // the crow flies: the car used to start facing away from the blue line)
                if driveLength(from: seg.a, to: target) < driveLength(from: seg.b, to: target) {
                    fromNode = seg.b
                    toNode = seg.a
                }
            } else if rng.unit() < 0.5 {
                fromNode = seg.b
                toNode = seg.a
            }
            let lane = map.lane(from: fromNode, to: toNode)
            let mid = CGPoint(x: (lane.start.x + lane.end.x) / 2, y: (lane.start.y + lane.end.y) / 2)
            let normal = CGPoint(x: sin(lane.heading), y: -cos(lane.heading))
            return [StartDef(position: mid, heading: lane.heading),
                    StartDef(position: CGPoint(x: mid.x - normal.x * CityMap.laneOffset * 2, y: mid.y - normal.y * CityMap.laneOffset * 2),
                             heading: lane.heading)]
        }

        if race {
            // Start somewhere, finish line across a street far away
            let startSegment = rng.int(segments.count)
            var finishSegment = startSegment
            var bestDistance: CGFloat = 0
            for _ in 0..<30 {
                let candidate = rng.int(segments.count)
                let d = midpoint(candidate).distance(to: midpoint(startSegment))
                if d > bestDistance && (d < 4200 || bestDistance < 2800) {
                    bestDistance = d
                    finishSegment = candidate
                }
            }
            let finishSeg = segments[finishSegment]
            let finish = SpotDef(center: midpoint(finishSegment), size: CGSize(width: 50, height: 150),
                                 angle: finishSeg.horizontal ? 0 : CGFloat.pi / 2)
            let starts = sideBySideStarts(on: startSegment, towards: finish.center)

            var obstacles: [ObstacleDef] = []
            for slot in slots {
                guard slot.segment != finishSegment, rng.unit() < 0.12 else { continue }
                obstacles.append(ObstacleDef(kind: .car, center: slot.center, size: carSize,
                                             angle: slot.angle + (rng.unit() < 0.5 ? 0 : CGFloat.pi), tint: rng.int(6)))
            }
            var arcade = Levels.arcadeLayout(map: map, round: round, race: race)
            obstacles += buildings(map: map, rng: &rng, alleyBlocks: arcade.alleyBlocks, alleys: &arcade.alleys)

            var bots: [BotStart] = []
            var attempts = 0
            // Traffic as dense as before over twice the streets
            while bots.count < 92 && attempts < 1600 {
                attempts += 1
                let index = rng.int(segments.count)
                let s = segments[index]
                let forward = rng.unit() < 0.5
                let start = BotStart(from: forward ? s.a : s.b, to: forward ? s.b : s.a, progress: rng.range(0.1, 0.9), tint: rng.int(6))
                let lane = map.lane(from: start.from, to: start.to)
                let p = CGPoint(x: lane.start.x + (lane.end.x - lane.start.x) * start.progress,
                                y: lane.start.y + (lane.end.y - lane.start.y) * start.progress)
                if starts.contains(where: { $0.position.distance(to: p) < 260 }) { continue }
                if bots.contains(where: { other in
                    let l = map.lane(from: other.from, to: other.to)
                    let q = CGPoint(x: l.start.x + (l.end.x - l.start.x) * other.progress, y: l.start.y + (l.end.y - l.start.y) * other.progress)
                    return q.distance(to: p) < 90
                }) { continue }
                bots.append(start)
            }
            // Three rivals on the grid behind the players, in both lanes
            let startSeg = segments[startSegment]
            let forwardLane = map.lane(from: startSeg.a, to: startSeg.b)
            let alongAB = abs(CGFloat.angleDelta(forwardLane.heading, starts[0].heading)) < 0.5
            let fromNode = alongAB ? startSeg.a : startSeg.b
            let toNode = alongAB ? startSeg.b : startSeg.a
            let back = CGPoint(x: -cos(starts[0].heading), y: -sin(starts[0].heading))
            let names = ["Kaan", "Derya", "Volkan", "Ece", "Mert", "Selin"]
            var racers: [RacerStart] = []
            for (k, (grid, gap)) in [(0, 78), (1, 78), (0, 156)].enumerated() {
                let p = starts[grid].position
                racers.append(RacerStart(position: CGPoint(x: p.x + back.x * CGFloat(gap), y: p.y + back.y * CGFloat(gap)),
                                         heading: starts[0].heading, from: fromNode, to: toNode,
                                         pace: [1.04, 0.97, 0.91][k], name: names[(round * 3 + k) % names.count], color: k))
            }
            // No traffic on the grid behind the players either
            bots.removeAll { bot in
                let l = map.lane(from: bot.from, to: bot.to)
                let q = CGPoint(x: l.start.x + (l.end.x - l.start.x) * bot.progress, y: l.start.y + (l.end.y - l.start.y) * bot.progress)
                return racers.contains { $0.position.distance(to: q) < 120 }
            }
            var level = LevelDef(nameTR: "Yoğun Trafik", nameEN: "Rush Hour", starts: starts, spots: [finish, finish], obstacles: obstacles,
                                 world: worldSize, city: map, bots: bots, race: true)
            level.racers = racers
            level.finishStreet = (finishSeg.a, finishSeg.b)
            Levels.finishArcade(&level, arcade)
            return level
        }

        // Spot Wars: four free bays on one interior street, two on each curb; the rest of the
        // street is parked up. Drivers hunting for a spot come for the same bays.
        let interior = segments.indices.filter { segments[$0].interior }
        let targetSegment = interior[rng.int(interior.count)]
        let targetSeg = segments[targetSegment]
        let perSide = slots.filter { $0.segment == targetSegment && $0.side == -1 }.count
        guard perSide >= 6 else { return all[0] }
        var chosen: [Slot] = []
        for side in [-1, 1] {
            let first = 1 + rng.int(perSide / 2 - 1)
            let second = min(perSide - 2, first + 2 + rng.int(perSide / 2))
            for index in [first, second] {
                if let slot = slots.first(where: { $0.segment == targetSegment && $0.side == side && $0.index == index }) {
                    chosen.append(slot)
                }
            }
        }
        guard chosen.count == 4 else { return all[0] }
        let spotSize = CGSize(width: CityMap.slotLength, height: CityMap.slotWidth)
        let freeSpots: [FreeSpot] = chosen.map { slot in
            // The right-hand curb: east and north lanes have it on the -y and +x side
            let forward = targetSeg.horizontal ? slot.side < 0 : slot.side > 0
            return FreeSpot(def: SpotDef(center: slot.center, size: spotSize, angle: slot.angle),
                            entry: forward ? targetSeg.a : targetSeg.b, exit: forward ? targetSeg.b : targetSeg.a)
        }
        // Taxi: the customer waits by the first bay (the only one left open on that street); the
        // ride goes to one free bay on a street far away
        var destination: SpotDef?
        var destinationSlot: Slot?
        var destinationSegment = -1
        if taxi {
            let pickup = freeSpots[0].def.center
            for _ in 0..<80 {
                let candidate = interior[rng.int(interior.count)]
                if candidate != targetSegment && midpoint(candidate).distance(to: pickup) > 1700 {
                    destinationSegment = candidate
                    break
                }
            }
            if destinationSegment < 0 { destinationSegment = interior.first { $0 != targetSegment } ?? targetSegment }
            let side = rng.unit() < 0.5 ? -1 : 1
            let count = slots.filter { $0.segment == destinationSegment && $0.side == side }.count
            let index = 1 + rng.int(max(1, count - 2))
            destinationSlot = slots.first { $0.segment == destinationSegment && $0.side == side && $0.index == index }
            if let slot = destinationSlot {
                destination = SpotDef(center: slot.center, size: spotSize, angle: slot.angle)
            }
        }
        let openSlots: [Slot] = taxi ? [chosen[0]] + (destinationSlot.map { [$0] } ?? []) : chosen
        let spots = destination.map { [$0, $0] } ?? [freeSpots[0].def, freeSpots[2].def]
        let targetCenter = midpoint(targetSegment)

        // Start: a street far away from the target
        var startSegment = 0
        for _ in 0..<40 {
            let candidate = rng.int(segments.count)
            let s = segments[candidate]
            let mid = CGPoint(x: (map.position(of: s.a).x + map.position(of: s.b).x) / 2,
                              y: (map.position(of: s.a).y + map.position(of: s.b).y) / 2)
            startSegment = candidate
            if mid.distance(to: targetCenter) > 2100 { break }
        }
        let startSeg = segments[startSegment]
        // Facing the way the route to the target goes
        let flip = driveLength(from: startSeg.a, to: targetCenter) < driveLength(from: startSeg.b, to: targetCenter)
        let fromNode = flip ? startSeg.b : startSeg.a
        let toNode = flip ? startSeg.a : startSeg.b
        let lane = map.lane(from: fromNode, to: toNode)
        let mid = CGPoint(x: (lane.start.x + lane.end.x) / 2, y: (lane.start.y + lane.end.y) / 2)
        let normal = CGPoint(x: sin(lane.heading), y: -cos(lane.heading))
        // Slot 0 in the right lane, slot 1 in the left lane, side by side
        let starts = [StartDef(position: mid, heading: lane.heading),
                      StartDef(position: CGPoint(x: mid.x - normal.x * CityMap.laneOffset * 2, y: mid.y - normal.y * CityMap.laneOffset * 2),
                               heading: lane.heading)]

        // Parked cars: the target street is nearly full (only the free bays are open)
        var obstacles: [ObstacleDef] = []
        for slot in slots {
            if openSlots.contains(where: { $0.segment == slot.segment && $0.side == slot.side && $0.index == slot.index }) { continue }
            let chance: CGFloat = slot.segment == targetSegment || slot.segment == destinationSegment ? 0.9 : 0.2
            guard rng.unit() < chance else { continue }
            let jitter = rng.range(-6, 6)
            let center = slot.angle == 0 ? CGPoint(x: slot.center.x + jitter, y: slot.center.y)
                                         : CGPoint(x: slot.center.x, y: slot.center.y + jitter)
            obstacles.append(ObstacleDef(kind: .car, center: center, size: carSize,
                                         angle: slot.angle + (rng.unit() < 0.5 ? 0 : CGFloat.pi), tint: rng.int(6)))
        }

        // The hunters: placed so that, at a hunter's pace, they reach the street before, around
        // and after the time a player needs (the drive there at city speed plus parking)
        let playerDrive = driveLength(from: toNode, to: targetCenter) + lane.end.distance(to: mid)
        let playerTime = playerDrive / 200 + 7
        var hunters: [HunterStart] = []
        var taken: [CGPoint] = starts.map { $0.position }
        // (taxi: the rival taxis all go for the customer's bay)
        let shares: [CGFloat] = taxi ? [0.55, 0.95, 1.35] : [0.45, 0.8, 1.1, 1.6]
        for (k, share) in shares.enumerated() {
            let spot = taxi ? 0 : k
            let dist = map.distances(to: freeSpots[spot].entry, avoiding: (freeSpots[spot].entry, freeSpots[spot].exit))
            let wanted = max(380, (CGFloat(share) * playerTime - 2.5) * 75)
            var best: BotStart?
            var bestMiss = CGFloat.greatestFiniteMagnitude
            for u in 0..<map.nodeCount {
                for v in map.neighbors(u) {
                    // Not on the target street itself, nor on the players' start street
                    if Set([u, v]) == Set([targetSeg.a, targetSeg.b]) || Set([u, v]) == Set([startSeg.a, startSeg.b]) { continue }
                    // From v it must go on without turning back to u (cars never make U-turns)
                    if v != freeSpots[spot].entry {
                        let onward = map.neighbors(v).filter { $0 != u }
                        guard let next = onward.min(by: { map.position(of: v).distance(to: map.position(of: $0)) + dist[$0]
                                                         < map.position(of: v).distance(to: map.position(of: $1)) + dist[$1] }),
                              map.position(of: v).distance(to: map.position(of: next)) + dist[next] <= dist[v] + 1 else { continue }
                    }
                    let l = map.lane(from: u, to: v)
                    let laneLength = l.start.distance(to: l.end)
                    let remaining = wanted - dist[v]
                    let progress = 1 - remaining / laneLength
                    let clamped = max(0.15, min(0.85, progress))
                    let p = CGPoint(x: l.start.x + (l.end.x - l.start.x) * clamped, y: l.start.y + (l.end.y - l.start.y) * clamped)
                    if taken.contains(where: { $0.distance(to: p) < 300 }) { continue }
                    let miss = abs(progress - clamped) * laneLength + rng.unit() * 40
                    if miss < bestMiss {
                        bestMiss = miss
                        best = BotStart(from: u, to: v, progress: clamped, tint: rng.int(6))
                    }
                }
            }
            if let start = best {
                hunters.append(HunterStart(start: start, spot: spot))
                let l = map.lane(from: start.from, to: start.to)
                taken.append(CGPoint(x: l.start.x + (l.end.x - l.start.x) * start.progress,
                                     y: l.start.y + (l.end.y - l.start.y) * start.progress))
            }
        }

        var arcade = Levels.arcadeLayout(map: map, round: round, race: race)
        obstacles += buildings(map: map, rng: &rng, alleyBlocks: arcade.alleyBlocks, alleys: &arcade.alleys)

        // Traffic
        var bots: [BotStart] = []
        var attempts = 0
        while bots.count < 52 && attempts < 1100 {
            attempts += 1
            let index = rng.int(segments.count)
            if index == startSegment { continue }
            let s = segments[index]
            let forward = rng.unit() < 0.5
            let candidate = BotStart(from: forward ? s.a : s.b, to: forward ? s.b : s.a, progress: rng.range(0.1, 0.9), tint: rng.int(6))
            let lane = map.lane(from: candidate.from, to: candidate.to)
            let p = CGPoint(x: lane.start.x + (lane.end.x - lane.start.x) * candidate.progress,
                            y: lane.start.y + (lane.end.y - lane.start.y) * candidate.progress)
            if bots.contains(where: { other in
                let l = map.lane(from: other.from, to: other.to)
                let q = CGPoint(x: l.start.x + (l.end.x - l.start.x) * other.progress, y: l.start.y + (l.end.y - l.start.y) * other.progress)
                return q.distance(to: p) < 90
            }) { continue }
            bots.append(candidate)
        }

        // Ordinary traffic keeps away from where the hunters start
        bots.removeAll { bot in
            let l = map.lane(from: bot.from, to: bot.to)
            let p = CGPoint(x: l.start.x + (l.end.x - l.start.x) * bot.progress, y: l.start.y + (l.end.y - l.start.y) * bot.progress)
            return taken.contains { $0.distance(to: p) < 90 }
        }
        var level = LevelDef(nameTR: "Şehir", nameEN: "City", starts: starts, spots: spots, obstacles: obstacles,
                             world: worldSize, city: map, bots: bots)
        level.freeSpots = taxi ? [freeSpots[0]] : freeSpots
        level.hunters = hunters
        if taxi, let destination = destination {
            // The customer stands on the pavement behind the bay, facing the street
            let slot = chosen[0]
            let out = CGFloat(slot.side) * 26
            let customer = targetSeg.horizontal ? CGPoint(x: slot.center.x, y: slot.center.y + out)
                                                : CGPoint(x: slot.center.x + out, y: slot.center.y)
            let facing: CGFloat = targetSeg.horizontal ? (slot.side < 0 ? CGFloat.pi / 2 : -CGFloat.pi / 2)
                                                       : (slot.side < 0 ? 0 : CGFloat.pi)
            level.taxi = TaxiDef(customer: customer, facing: facing, destination: destination,
                                 rider: Rider(rawValue: round % Rider.allCases.count) ?? .hurry)
        }
        Levels.finishArcade(&level, arcade)
        return level
    }

    static let alleyWidth: CGFloat = 90

    /// Arcade extras, drawn from their own random stream so the rest of the map stays the same.
    struct ArcadeLayout {
        var alleyBlocks: Set<Int>
        var alleys: [CGRect] = []
        var rng: SplitMix64
        let weather: Weather
    }

    static func arcadeLayout(map: CityMap, round: Int, race: Bool) -> ArcadeLayout {
        var rng = SplitMix64(seed: (UInt64(round + 11) &* 0x9E37_79B9_7F4A_7C15) ^ (race ? 0x5151 : 0x7373))
        var blocks = Array(map.blocks.indices)
        blocks.shuffle(using: &rng)
        // Every round shows a different sky: races start at night, city rounds in the rain
        let weather = Weather(rawValue: (round + (race ? 1 : 2)) % 4) ?? .day

        let arguments = ProcessInfo.processInfo.arguments
        let forced: Weather? = arguments.contains("-dayweather") ? .day : (arguments.contains("-nightweather") ? .night : nil)
        return ArcadeLayout(alleyBlocks: Set(blocks.prefix(map.blocks.count >= 20 ? 5 : 3)), rng: rng, weather: forced ?? weather)
    }

    /// Ramps in the alleys, construction cones, barrels and bins, and the weather.
    static func finishArcade(_ level: inout LevelDef, _ layout: ArcadeLayout) {
        guard let map = level.city else { return }
        var rng = layout.rng
        level.alleys = layout.alleys
        level.weather = layout.weather
        level.ramps = layout.alleys.map { RampDef(center: CGPoint(x: $0.midX, y: $0.midY), alongX: true) }
        let keepClear = level.starts.map { $0.position } + level.spots.map { $0.center } + level.freeSpots.map { $0.def.center }
        let parked = level.obstacles.filter { $0.kind == .car }.map { $0.center }
        func free(_ p: CGPoint, _ radius: CGFloat) -> Bool {
            !keepClear.contains { $0.distance(to: p) < 220 } && !parked.contains { $0.distance(to: p) < radius }
                && !level.alleys.contains { $0.insetBy(dx: -30, dy: -30).contains(p) }
        }
        var props: [PropDef] = []
        // Road works: a taper of cones from the parking strip into the lane on a few streets
        let scale = max(1, map.blocks.count / 12)
        for _ in 0..<(5 * scale) {
            let horizontal = rng.unit() < 0.5
            let side: CGFloat = rng.unit() < 0.5 ? -1 : 1
            if horizontal {
                let j = rng.int(map.rows)
                let i = rng.int(map.cols - 1)
                let x0 = map.xs[i] + 220 + rng.range(0, 200)
                let barricade = CGPoint(x: x0 - 30, y: map.ys[j] + side * CityMap.stripOffset)
                if free(barricade, 50) { props.append(PropDef(kind: 3, position: barricade, yaw: CGFloat.pi / 2)) }
                for k in 0..<7 {
                    let p = CGPoint(x: x0 + CGFloat(k) * 34, y: map.ys[j] + side * (CityMap.stripOffset - CGFloat(k) * 7))
                    if free(p, 40) { props.append(PropDef(kind: 0, position: p)) }
                }
            } else {
                let i = rng.int(map.cols)
                let j = rng.int(map.rows - 1)
                let y0 = map.ys[j] + 220 + rng.range(0, 150)
                let barricade = CGPoint(x: map.xs[i] + side * CityMap.stripOffset, y: y0 - 30)
                if free(barricade, 50) { props.append(PropDef(kind: 3, position: barricade, yaw: 0)) }
                for k in 0..<7 {
                    let p = CGPoint(x: map.xs[i] + side * (CityMap.stripOffset - CGFloat(k) * 7), y: y0 + CGFloat(k) * 34)
                    if free(p, 40) { props.append(PropDef(kind: 0, position: p)) }
                }
            }
        }
        // Barrels at a few intersection corners
        for _ in 0..<(6 * scale) {
            let node = rng.int(map.nodeCount)
            let c = map.position(of: node)
            let sx: CGFloat = rng.unit() < 0.5 ? -1 : 1
            let sy: CGFloat = rng.unit() < 0.5 ? -1 : 1
            for k in 0..<2 {
                let p = CGPoint(x: c.x + sx * (CityMap.roadHalf - 14), y: c.y + sy * (CityMap.roadHalf - 14 - CGFloat(k) * 18))
                if free(p, 30) && p.x > 20 && p.y > 20 && p.x < level.world.width - 20 && p.y < level.world.height - 20 {
                    props.append(PropDef(kind: 1, position: p))
                }
            }
        }
        // Bins at the curb along the blocks
        for block in map.blocks {
            for _ in 0..<2 {
                let alongX = rng.unit() < 0.5
                let p = alongX
                    ? CGPoint(x: rng.range(block.minX + 60, block.maxX - 60), y: rng.unit() < 0.5 ? block.minY + 10 : block.maxY - 10)
                    : CGPoint(x: rng.unit() < 0.5 ? block.minX + 10 : block.maxX - 10, y: rng.range(block.minY + 60, block.maxY - 60))
                if free(p, 30) { props.append(PropDef(kind: 2, position: p)) }
            }
        }
        level.props = props
    }

    /// Landmark kinds, stored in a building's `tint` (100+).
    static let gasStation = 100
    static let parkingGarage = 101
    static let park = 102

    /// Buildings: 2–3 columns x 2 rows per block, set back behind a sidewalk. One block is a park,
    /// and a few corner lots hold a gas station or a parking garage.
    private static func buildings(map: CityMap, rng: inout SplitMix64, alleyBlocks: Set<Int> = [],
                                  alleys: inout [CGRect]) -> [ObstacleDef] {
        var result: [ObstacleDef] = []
        let blocks = map.blocks
        var order = Array(blocks.indices)
        order.shuffle(using: &rng)
        let parkBlock = order.first ?? -1
        let gasBlocks = Set(order.dropFirst().prefix(2))
        let garageBlocks = Set(order.dropFirst(3).prefix(2))
        for (index, block) in blocks.enumerated() {
            let inner = block.insetBy(dx: 36, dy: 36)
            if index == parkBlock {
                result.append(ObstacleDef(kind: .building, center: CGPoint(x: inner.midX, y: inner.midY), size: inner.size,
                                          angle: 0, tint: park, height: 0))
                continue
            }
            let columns = 2 + rng.int(2)
            let gap: CGFloat = 22
            // An alley block keeps a wide drivable lane between its two rows of buildings
            let rowGap: CGFloat = alleyBlocks.contains(index) ? Levels.alleyWidth : gap
            if alleyBlocks.contains(index) {
                let y = inner.minY + (inner.height - rowGap) / 2
                alleys.append(CGRect(x: block.minX, y: y, width: block.width, height: rowGap))
            }
            let width = (inner.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (inner.height - rowGap) / 2
            for c in 0..<columns {
                for r in 0..<2 {
                    let center = CGPoint(x: inner.minX + width * (CGFloat(c) + 0.5) + gap * CGFloat(c),
                                         y: inner.minY + height * (CGFloat(r) + 0.5) + rowGap * CGFloat(r))
                    var tint = rng.int(8)
                    let floors = rng.range(7, 26)
                    if c == 0 && r == 0 {
                        if gasBlocks.contains(index) { tint = gasStation }
                        if garageBlocks.contains(index) { tint = parkingGarage }
                    }
                    result.append(ObstacleDef(kind: .building, center: center, size: CGSize(width: width, height: height),
                                              angle: 0, tint: tint, height: tint >= 100 ? 12 : floors))
                }
            }
        }
        return result
    }
}

// MARK: - Traffic

struct Bot {
    var position: CGPoint
    var heading: CGFloat
    var speed: CGFloat
    var from: Int
    var to: Int
    var waypoints: [CGPoint]
    var waiting: CGFloat = 0
    var ignoreBots: CGFloat = 0
    var braking = false
    /// Knocked by a crash: slides and spins for a moment before driving on.
    var stunned: CGFloat = 0
    var shove = CGVector.zero
    var spin: CGFloat = 0
    let tint: Int
    /// The driver: how fast they like to go (share of the speed limit) and how much room they
    /// leave to the car ahead (seconds), so the traffic does not move as one block.
    var pace: CGFloat = 1
    var headway: CGFloat = 1.3
    /// The street it takes at the end of this one (chosen early, so it slows for the turn).
    var next: Int = -1
    /// Sideways shift from its lane while going round a car stopped in it (+ = left).
    var offset: CGFloat = 0
    var passing = false
    var honkedAt: CGFloat = -10
    /// The bot it is waiting for this step (-1: none, or not a bot).
    var blocker = -1
    /// Rolling back a little to untangle from cars that wait for each other.
    var backing: CGFloat = 0
    /// Spot Wars: the free bay this driver is hunting for (-1: an ordinary driver), whether it is
    /// on the bay's street heading for it, pulling in (0...1) and parked.
    var hunt = -1
    var approach = false
    var parkT: CGFloat = -1
    var parkFrom = CGPoint.zero
    var parkFromHeading: CGFloat = 0
    var parked = false
    /// Hazard lights on (looking for a spot).
    var hazard: Bool { hunt >= 0 && !parked }
    /// A rival racer: how fast it drives, the finish street's end it heads for (and the other
    /// end), and whether it crossed the line.
    var racer = false
    var raceEntry = -1
    var raceExit = -1
    var raceGoal = 0
    var onFinal = false
    var raceDone = false
    /// Seconds a racer has been stuck behind a slower car.
    var trailing: CGFloat = 0

    var box: OBB { OBB(center: position, size: Levels.carSize, angle: heading) }
}

/// Lane-following traffic with drivers of their own: each keeps a following distance to the car
/// ahead (slowing smoothly rather than stopping dead), slows down before a turn, stops at red
/// lights and for people on the road, honks at a car blocking its lane and, after a while, pulls
/// out round it when the oncoming lane is clear. Where two paths cross, whoever gets there later
/// waits short of the crossing, and cars are never drawn inside each other.
final class Traffic {
    let map: CityMap
    private(set) var bots: [Bot] = []
    private var rng: SplitMix64

    private let cruise: CGFloat = 78
    /// Seconds since the level started; drives the traffic lights.
    private(set) var clock: CGFloat = 0
    private let cornerSpeed: CGFloat = 40
    /// Where bots honked this step (the scene plays the horns it can hear).
    private(set) var honks: [CGPoint] = []
    /// For the traffic check: cars found inside each other (and pushed apart), cars let through
    /// others out of sight, and untangling roll-backs.
    private(set) var overlaps = 0
    private(set) var ghosts = 0
    private(set) var backoffs = 0
    /// Out of the players' sight (past the fog): only there may a long-stuck car slip through.
    private let sight: CGFloat = 2400
    /// The traffic check only: the old drivers (no giving way, slipping through after 2.5 s,
    /// overlaps counted but left as they are), to compare with.
    var legacy = false

    // MARK: Spot Wars

    /// The free bays on the target street, the drive to each bay's lane, and the bays gone
    /// (to a hunter or a player).
    private(set) var spots: [FreeSpot] = []
    private var spotDistances: [[CGFloat]] = []
    private(set) var taken = Set<Int>()
    /// Bays hunters took this step (bay, bot), for the scene to show and send.
    private(set) var takes: [(spot: Int, bot: Int)] = []
    /// Only the host decides when a hunter has taken a bay (the guest is told).
    var authority = true

    // MARK: Rival racers

    /// The finish street and the drive to each of its ends; racers wait on the grid until released.
    private var finishStreet: (a: Int, b: Int, point: CGPoint)?
    private var finishDistances: [[CGFloat]] = []
    var racersReleased = false
    private(set) var raceClock: CGFloat = 0
    /// Racers that crossed the line (bot, seconds since the start), in order.
    private(set) var raceFinishes: [(bot: Int, time: CGFloat)] = []
    private let racerTop: CGFloat = 360
    /// Racers further than this from every player drive through traffic (out of view, so the
    /// race doesn't hang on a jam nobody sees); near a player they race it for real.
    private let racerFreeRange: CGFloat = 700
    /// Catch-up per racer (bot index → speed factor), set by the race: a racer far behind the
    /// player drives a little faster, one far ahead a little slower, so the race stays close.
    var racerBoost: [Int: CGFloat] = [:]

    init(map: CityMap, starts: [BotStart], seed: UInt64, spots: [FreeSpot] = [], hunters: [HunterStart] = [],
         racers: [RacerStart] = [], finish: (a: Int, b: Int, point: CGPoint)? = nil) {
        self.map = map
        self.spots = spots
        spotDistances = spots.map { map.distances(to: $0.entry, avoiding: ($0.entry, $0.exit)) }
        rng = SplitMix64(seed: seed)
        for start in starts {
            let lane = map.lane(from: start.from, to: start.to)
            let p = CGPoint(x: lane.start.x + (lane.end.x - lane.start.x) * start.progress,
                            y: lane.start.y + (lane.end.y - lane.start.y) * start.progress)
            var bot = Bot(position: p, heading: lane.heading, speed: cruise, from: start.from, to: start.to,
                          waypoints: [lane.end], tint: start.tint)
            bot.pace = rng.range(0.82, 1.14)
            bot.headway = rng.range(1.0, 1.8)
            bot.speed = cruise * bot.pace
            bots.append(bot)
        }
        for hunter in hunters where spots.indices.contains(hunter.spot) {
            let start = hunter.start
            let lane = map.lane(from: start.from, to: start.to)
            let p = CGPoint(x: lane.start.x + (lane.end.x - lane.start.x) * start.progress,
                            y: lane.start.y + (lane.end.y - lane.start.y) * start.progress)
            var bot = Bot(position: p, heading: lane.heading, speed: cruise, from: start.from, to: start.to,
                          waypoints: [lane.end], tint: start.tint)
            // In a hurry, and close behind the car ahead
            bot.pace = 1.15
            bot.headway = 1.0
            bot.speed = cruise * bot.pace
            bot.hunt = hunter.spot
            bots.append(bot)
        }
        if let finish = finish, !racers.isEmpty {
            finishStreet = finish
            finishDistances = [map.distances(to: finish.a, avoiding: (finish.a, finish.b)),
                               map.distances(to: finish.b, avoiding: (finish.a, finish.b))]
            for racer in racers {
                let lane = map.lane(from: racer.from, to: racer.to)
                var bot = Bot(position: racer.position, heading: racer.heading, speed: 0, from: racer.from, to: racer.to,
                              waypoints: [lane.end], tint: racer.color)
                bot.racer = true
                bot.pace = racer.pace
                bot.headway = 0.45
                // The finish street's nearer end (by road) is where it drives onto it
                let viaA = finishDistances[0][racer.to], viaB = finishDistances[1][racer.to]
                bot.raceGoal = viaA <= viaB ? 0 : 1
                bot.raceEntry = viaA <= viaB ? finish.a : finish.b
                bot.raceExit = viaA <= viaB ? finish.b : finish.a
                if racer.to == bot.raceEntry && racer.from == bot.raceExit {
                    // Already on the finish street the wrong way: the other end is the way in
                    swap(&bot.raceEntry, &bot.raceExit)
                    bot.raceGoal = 1 - bot.raceGoal
                }
                bots.append(bot)
            }
        }
    }

    /// A player took bay `spot` (or the host says a hunter did): hunters going for it look for another.
    func claim(_ spot: Int) {
        guard spots.indices.contains(spot) else { return }
        taken.insert(spot)
    }

    /// The host's word that hunter `bot` took bay `spot`: it is put in the bay at once.
    func applyTake(spot: Int, bot index: Int) {
        guard spots.indices.contains(spot), bots.indices.contains(index) else { return }
        taken.insert(spot)
        var bot = bots[index]
        bot.hunt = spot
        bot.parked = true
        bot.parkT = -1
        bot.approach = false
        bot.speed = 0
        bot.braking = false
        bot.position = spots[spot].def.center
        bot.heading = parkHeading(spot, from: bot.heading)
        bots[index] = bot
    }

    var freeSpotCount: Int { spots.count - taken.count }

    /// The bay's own angle, turned to match the lane the car came along.
    private func parkHeading(_ spot: Int, from heading: CGFloat) -> CGFloat {
        let angle = spots[spot].def.angle
        return abs(CGFloat.angleDelta(heading, angle)) < CGFloat.pi / 2 ? angle : angle + CGFloat.pi
    }

    /// The nearest bay still free that no other hunter is going for (else any free one).
    private func retarget(_ index: Int) {
        var bot = bots[index]
        let others = Set(bots.indices.filter { $0 != index && bots[$0].hunt >= 0 && !bots[$0].parked }.map { bots[$0].hunt })
        let free = spots.indices.filter { !taken.contains($0) }
        let preferred = free.filter { !others.contains($0) }
        let pool = preferred.isEmpty ? free : preferred
        let here = bot.to
        bot.hunt = pool.min { spotDistances[$0][here] < spotDistances[$1][here] } ?? -1
        bot.approach = false
        bot.parkT = -1
        bot.next = -1
        bots[index] = bot
    }

    /// Whether a player's car is in or right by bay `spot` (a hunter will not pull in on them).
    private func playerAt(_ spot: Int, players: ArraySlice<CGPoint>) -> Bool {
        players.contains { $0.distance(to: spots[spot].def.center) < 58 }
    }

    /// A player crashed into bot `index`: it is shoved and spun, then drives on.
    func hit(_ index: Int, shove: CGVector, spin: CGFloat) {
        guard bots.indices.contains(index) else { return }
        // It keeps its own momentum plus the blow, then the tyres scrub the slide off
        let bot = bots[index]
        if bot.parkT >= 0 && !bot.parked {
            bots[index].parkT = -1
            bots[index].approach = false
        }
        bots[index].stunned = 1.1
        bots[index].shove = CGVector(dx: cos(bot.heading) * bot.speed + shove.dx, dy: sin(bot.heading) * bot.speed + shove.dy)
        bots[index].spin = spin
        bots[index].speed = 0
    }

    /// Picks the street after this one (not straight back), once.
    private func planNext(_ bot: inout Bot) {
        guard bot.next < 0 else { return }
        var options = map.neighbors(bot.to).filter { $0 != bot.from }
        if options.isEmpty { options = map.neighbors(bot.to) }
        if bot.racer && !bot.raceDone && finishDistances.indices.contains(bot.raceGoal) {
            // A racer takes the shortest way to the finish street
            if bot.to == bot.raceEntry && options.contains(bot.raceExit) {
                bot.next = bot.raceExit
                return
            }
            let dist = finishDistances[bot.raceGoal]
            let here = map.position(of: bot.to)
            if let best = options.min(by: { here.distance(to: map.position(of: $0)) + dist[$0]
                                             < here.distance(to: map.position(of: $1)) + dist[$1] }) {
                bot.next = best
                return
            }
        }
        if bot.hunt >= 0 && !bot.parked && spots.indices.contains(bot.hunt) {
            // A hunter takes the shortest way to its bay's lane
            let spot = spots[bot.hunt]
            if bot.to == spot.entry && options.contains(spot.exit) {
                bot.next = spot.exit
                return
            }
            let dist = spotDistances[bot.hunt]
            let here = map.position(of: bot.to)
            if let best = options.min(by: { here.distance(to: map.position(of: $0)) + dist[$0]
                                             < here.distance(to: map.position(of: $1)) + dist[$1] }) {
                bot.next = best
                return
            }
        }
        bot.next = options[rng.int(options.count)]
    }

    /// Spot Wars: a hunter pulling into its bay along an S-curve from its lane (2 s), then
    /// parked with the engine off. Returns true when it handled the bot this step.
    private func stepHunter(_ index: Int, _ dt: CGFloat, players: ArraySlice<CGPoint>) -> Bool {
        var bot = bots[index]
        if bot.parked {
            bot.speed = 0
            bot.braking = false
            bots[index] = bot
            return true
        }
        guard bot.hunt >= 0, spots.indices.contains(bot.hunt) else { return false }
        if taken.contains(bot.hunt) {
            // Its bay is gone: a honk, then the next one
            honks.append(bot.position)
            retarget(index)
            return false
        }
        let spot = spots[bot.hunt]
        if bot.parkT >= 0 {
            if bot.parkT < 0.35 && playerAt(bot.hunt, players: players) {
                // A player is in the bay: give up on it
                honks.append(bot.position)
                bots[index].parkT = -1
                bots[index].approach = false
                bots[index].waypoints = []
                bots[index].from = spot.entry
                bots[index].to = spot.exit
                retarget(index)
                return false
            }
            bot.parkT = min(1, bot.parkT + dt / 2.0)
            let t = bot.parkT * bot.parkT * (3 - 2 * bot.parkT)
            let f = CGPoint(x: cos(bot.parkFromHeading), y: sin(bot.parkFromHeading))
            let p0 = bot.parkFrom, p3 = spot.def.center
            let p1 = CGPoint(x: p0.x + f.x * 28, y: p0.y + f.y * 28)
            let p2 = CGPoint(x: p3.x - f.x * 28, y: p3.y - f.y * 28)
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            let next = CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
            let dx = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
            let dy = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
            bot.speed = next.distance(to: bot.position) / max(dt, 0.001)
            bot.position = next
            if hypot(dx, dy) > 0.01 { bot.heading = atan2(dy, dx) }
            bot.braking = true
            if bot.parkT >= 1 {
                bot.heading = parkHeading(bot.hunt, from: bot.parkFromHeading)
                if authority {
                    bot.parked = true
                    bot.speed = 0
                    bot.braking = false
                    taken.insert(bot.hunt)
                    takes.append((bot.hunt, index))
                } else {
                    // The guest waits for the host to say so, standing in the bay
                    bot.speed = 0
                }
            }
            bots[index] = bot
            return true
        }
        if bot.approach && bot.waypoints.isEmpty {
            if playerAt(bot.hunt, players: players) {
                honks.append(bot.position)
                bots[index].approach = false
                retarget(index)
                return false
            }
            bot.parkT = 0
            bot.parkFrom = bot.position
            bot.parkFromHeading = bot.heading
            bots[index] = bot
            return true
        }
        return false
    }

    /// Whether the turn into `next` is a real turn (not straight on).
    private func turns(_ bot: Bot) -> Bool {
        guard bot.next >= 0 else { return false }
        let a = map.lane(from: bot.from, to: bot.to).heading
        let b = map.lane(from: bot.to, to: bot.next).heading
        return abs(CGFloat.angleDelta(a, b)) > 0.4
    }

    /// `blockers`: player cars (the first `playerCars`) and people on the road the bots must not
    /// drive into. Bots honk at and pass round player cars only, never people.
    func step(_ dt: CGFloat, blockers: [CGPoint], playerCars: Int = 1) {
        clock += dt
        honks.removeAll()
        takes.removeAll()
        if racersReleased { raceClock += dt }
        for index in bots.indices {
            var bot = bots[index]
            if bot.stunned > 0 {
                // Sliding and spinning after a hit, then back to its lane
                bot.stunned -= dt
                bot.position.x += bot.shove.dx * dt
                bot.position.y += bot.shove.dy * dt
                bot.heading += bot.spin * dt
                let fade = exp(-dt * 4.2)
                bot.shove = CGVector(dx: bot.shove.dx * fade, dy: bot.shove.dy * fade)
                bot.spin *= fade
                bot.speed = 0
                bot.braking = true
                bots[index] = bot
                continue
            }
            if bot.hunt >= 0 || bot.parked {
                if stepHunter(index, dt, players: blockers.prefix(playerCars)) { continue }
                bot = bots[index]
            }
            if bot.racer && racersReleased && blockers.prefix(playerCars).allSatisfy({ $0.distance(to: bot.position) > racerFreeRange }) {
                bot.ignoreBots = max(bot.ignoreBots, 0.1)
            }
            if bot.racer && !racersReleased {
                bot.speed = 0
                bot.braking = true
                bots[index] = bot
                continue
            }
            if bot.racer && bot.onFinal && bot.waypoints.isEmpty {
                // Across the line: the race is over for it, it cruises on as traffic
                bot.onFinal = false
                bot.raceDone = true
                bot.racer = false
                bot.pace = 1.1
                bot.headway = 1.2
                raceFinishes.append((index, raceClock))
            }
            if bot.backing > 0 {
                // Rolls back slowly to make room, unless a car is right behind it
                bot.backing -= dt
                bot.speed = 0
                bot.braking = true
                bot.blocker = -1
                let ch = cos(bot.heading), sh = sin(bot.heading)
                var room = true
                for other in bots.indices where other != index {
                    let vx = bots[other].position.x - bot.position.x, vy = bots[other].position.y - bot.position.y
                    guard abs(vx) < 80 && abs(vy) < 80 else { continue }
                    let forward = vx * ch + vy * sh
                    if forward < 0 && forward > -60 && abs(-vx * sh + vy * ch) < 26 { room = false; break }
                }
                if room {
                    bot.position.x -= ch * 24 * dt
                    bot.position.y -= sh * 24 * dt
                }
                bots[index] = bot
                continue
            }
            if bot.waypoints.isEmpty {
                planNext(&bot)
                bot.from = bot.to
                bot.to = bot.next
                bot.next = -1
                let lane = map.lane(from: bot.from, to: bot.to)
                bot.waypoints = [lane.start, lane.end]
                if bot.racer, let finish = finishStreet, bot.from == bot.raceEntry, bot.to == bot.raceExit {
                    // On the finish street: across the line (and a little past it)
                    let along = (finish.point.x - lane.start.x) * cos(lane.heading) + (finish.point.y - lane.start.y) * sin(lane.heading) + 40
                    let past = CGPoint(x: lane.start.x + cos(lane.heading) * along, y: lane.start.y + sin(lane.heading) * along)
                    bot.waypoints = [lane.start, past]
                    bot.onFinal = true
                }
                if bot.hunt >= 0, spots.indices.contains(bot.hunt), !taken.contains(bot.hunt),
                   bot.from == spots[bot.hunt].entry, bot.to == spots[bot.hunt].exit {
                    // On the bay's street: drive to just short of the bay, then pull in
                    let center = spots[bot.hunt].def.center
                    let along = (center.x - lane.start.x) * cos(lane.heading) + (center.y - lane.start.y) * sin(lane.heading) - 56
                    let stop = CGPoint(x: lane.start.x + cos(lane.heading) * along, y: lane.start.y + sin(lane.heading) * along)
                    bot.waypoints = along > 20 ? [lane.start, stop] : [stop]
                    bot.approach = true
                }
            }
            let goal = bot.waypoints[0]
            let lastLeg = bot.waypoints.count == 1
            let distanceToGoal = goal.distance(to: bot.position)
            if lastLeg && distanceToGoal < 160 { planNext(&bot) }
            // Steer for the lane point, shifted sideways while passing a stopped car
            let laneHeading = atan2(goal.y - bot.position.y, goal.x - bot.position.x)
            let target = CGPoint(x: goal.x - sin(laneHeading) * bot.offset, y: goal.y + cos(laneHeading) * bot.offset)
            let dx = target.x - bot.position.x
            let dy = target.y - bot.position.y
            let distance = hypot(dx, dy)
            let ahead = dx * cos(bot.heading) + dy * sin(bot.heading)
            // Approaching the stop line (end of the lane) on a red or late yellow light?
            var stopLine: CGFloat?
            if lastLeg && distance < 110 && !bot.approach && !bot.racer {
                let horizontal = bot.from / map.cols == bot.to / map.cols
                switch map.signal(at: bot.to, horizontal: horizontal, time: clock) {
                case .green: break
                case .yellow: if distance > 40 || bot.speed < 20 { stopLine = distance - 10 }
                case .red: stopLine = distance - 10
                }
            }
            if stopLine == nil && (distance < 24 || (distance < 70 && ahead < 0)) {
                bot.waypoints.removeFirst()
                bots[index] = bot
                continue
            }
            let desired = atan2(dy, dx)
            let error = CGFloat.angleDelta(bot.heading, desired)
            let maxTurn = 2.4 * dt
            bot.heading += max(-maxTurn, min(maxTurn, error))

            // The speed it wants: its own pace, slower in a bend and before a turn
            var v0 = (bot.racer ? racerTop * (racerBoost[index] ?? 1) : cruise) * bot.pace
            // A hunter that sees a player closing in on the same street puts its foot down
            if bot.hunt >= 0 && !bot.parked && spots.indices.contains(bot.hunt) {
                let bay = spots[bot.hunt].def.center
                if bay.distance(to: bot.position) < 1000 && blockers.prefix(playerCars).contains(where: { $0.distance(to: bay) < 900 }) {
                    v0 *= 1.4
                }
            }
            let corner = bot.racer ? 160 * bot.pace : cornerSpeed
            if abs(error) > 0.35 { v0 = min(v0, corner) }
            let brakeZone: CGFloat = bot.racer ? 260 : 140
            if lastLeg && turns(bot) && distance < brakeZone {
                v0 = min(v0, corner + (distance / brakeZone) * (v0 - corner))
            }
            if bot.passing { v0 = min(v0, bot.racer ? v0 : 55) }
            // A hunter on its bay's street slows down to pull in
            if bot.approach && lastLeg { v0 = min(v0, max(28, distance * 0.8)) }

            // The nearest thing ahead in its path: a car, a player, a person or the stop line
            var gap = CGFloat.greatestFiniteMagnitude
            var leaderSpeed: CGFloat = 0
            var blockedByPlayer = false
            var blocker = -1
            let ch = cos(bot.heading), sh = sin(bot.heading)
            func inPath(_ point: CGPoint) -> CGFloat? {
                let vx = point.x - bot.position.x, vy = point.y - bot.position.y
                let forward = vx * ch + vy * sh
                let lateral = abs(-vx * sh + vy * ch)
                return forward > 0 && forward < 200 && lateral < 24 ? forward : nil
            }
            for (k, point) in blockers.enumerated() {
                if let f = inPath(point), f - 46 < gap {
                    gap = f - 46
                    leaderSpeed = 0
                    blockedByPlayer = k < playerCars
                    blocker = -1
                }
            }
            if bot.ignoreBots <= 0 {
                for other in bots.indices where other != index {
                    let o = bots[other]
                    let vx = o.position.x - bot.position.x, vy = o.position.y - bot.position.y
                    guard abs(vx) < 220 && abs(vy) < 220 else { continue }
                    let forward = vx * ch + vy * sh
                    let lateral = -vx * sh + vy * ch
                    let co = cos(o.heading), so = sin(o.heading)
                    // The room the other car takes across and along our way, as it is turned to us
                    // (a car standing across the lane is much wider to us than one in it)
                    let c = abs(co * ch + so * sh), s = abs(so * ch - co * sh)
                    let across = 11 + 11 * c + 22 * s + 3
                    let along = 22 + 22 * c + 11 * s + 2
                    if forward > 0 && forward < 200 && abs(lateral) < across {
                        if forward - along < gap {
                            gap = forward - along
                            // Only the part of its speed along our way
                            leaderSpeed = max(0, o.speed * (co * ch + so * sh))
                            blockedByPlayer = false
                            blocker = other
                        }
                        continue
                    }
                    // Paths that cross ahead (a junction, a turn across the other lane): whoever
                    // gets to the crossing later waits short of it, like a driver giving way
                    let cross = ch * so - sh * co
                    guard !legacy, abs(cross) > 0.35, o.stunned <= 0 else { continue }
                    let mine = (vx * so - vy * co) / cross       // our way to the crossing point
                    let theirs = (vx * sh - vy * ch) / cross     // and theirs
                    let room: CGFloat = 36
                    guard mine > -room, mine < 170, theirs > -room, theirs < 170 else { continue }
                    let weAreIn = abs(mine) < room, theyAreIn = abs(theirs) < room
                    let giveWay: Bool
                    if weAreIn && theyAreIn {
                        giveWay = other < index
                    } else if weAreIn {
                        giveWay = false
                    } else if theyAreIn {
                        giveWay = true
                    } else if o.speed < 3 {
                        giveWay = false                          // it waits (a light, its own turn)
                    } else {
                        let tMine = (mine - room) / max(bot.speed, 20)
                        let tTheirs = (theirs - room) / max(o.speed, 20)
                        giveWay = tTheirs < 2.5 && (tTheirs < tMine - 0.1 || (abs(tTheirs - tMine) <= 0.1 && other < index))
                    }
                    if giveWay && mine - room < gap {
                        gap = max(0, mine - room)
                        leaderSpeed = 0
                        blockedByPlayer = false
                        blocker = other
                    }
                }
            }
            if let line = stopLine, line < gap {
                gap = max(0, line)
                leaderSpeed = 0
                blockedByPlayer = false
                blocker = -1
            }
            bot.blocker = blocker
            bots[index].blocker = blocker

            // Intelligent-driver following: free road acceleration, braking to keep the gap
            let aMax: CGFloat = bot.racer ? 230 : 95, comfortable: CGFloat = bot.racer ? 520 : 210
            let v = bot.speed
            var accel = aMax * (1 - pow(min(v / max(v0, 1), 1.5), 4))
            if gap < CGFloat.greatestFiniteMagnitude {
                let wanted = 22 + v * bot.headway + v * (v - leaderSpeed) / (2 * sqrt(aMax * comfortable))
                let s = max(gap, 1)
                accel -= aMax * (wanted / s) * (wanted / s)
            }
            accel = max(-420, accel)
            bot.speed = max(0, min(v0 * 1.05, v + accel * dt))
            if gap < 6 { bot.speed = min(bot.speed, 0) }
            // Brake lights with a little hysteresis: on for a real brake or a stop, off only once it
            // drives on (following a car, the brake force hovers round any one threshold and the
            // lamps flickered with it)
            if bot.braking {
                bot.braking = !(accel > -15 && bot.speed > 4)
            } else {
                bot.braking = accel < -70 || bot.speed < 1
            }

            // Stuck behind something: other bots squeeze past each other after a while; a
            // player's car standing in the lane gets a honk, then the bot pulls out round it
            if bot.speed < 4 && gap < 60 && stopLine == nil {
                bot.waiting += dt
                if blockedByPlayer && bot.waiting > 1.2 && clock - bot.honkedAt > 3.5 {
                    bot.honkedAt = clock
                    honks.append(bot.position)
                }
                // Cars waiting for each other in a ring (nose to nose in a junction): the first of
                // them rolls back a little to make room. Never through each other where a player
                // could see it; far out of sight a long-stuck car may slip through
                if legacy && !blockedByPlayer && bot.waiting > 2.5 {
                    bot.ignoreBots = 1.6
                    bot.waiting = 0
                    ghosts += 1
                }
                if !legacy && !blockedByPlayer && blocker >= 0 && bot.waiting > 2.5, let first = waitRing(from: index), first == index {
                    bot.backing = 1.1
                    bot.waiting = 0
                    backoffs += 1
                }
                // A racer stuck in traffic well away from the players slips through (nobody sees it)
                if bot.racer && !blockedByPlayer && bot.waiting > 1.2
                    && blockers.prefix(playerCars).allSatisfy({ $0.distance(to: bot.position) > 700 }) {
                    bot.ignoreBots = 1.0
                    bot.waiting = 0
                    ghosts += 1
                }
                if !legacy && !blockedByPlayer && bot.waiting > 8 && outOfSight(bot.position, players: blockers.prefix(playerCars)) {
                    bot.ignoreBots = 1.6
                    bot.waiting = 0
                    ghosts += 1
                }
                if blockedByPlayer && bot.waiting > 2.5 && !bot.passing && oncomingClear(bot) {
                    bot.passing = true
                }
            } else if gap > 120 || stopLine != nil {
                bot.waiting = 0
            }
            if bot.racer && !bot.passing && gap < 170 && leaderSpeed < v0 * 0.7 && stopLine == nil && oncomingClear(bot) {
                bot.passing = true
            }
            // A racer stuck behind slow traffic with no gap to pass: out of the players' sight it
            // slips by (in view it has to wait for a gap, like the player)
            if bot.racer && !bot.passing && gap < 150 && leaderSpeed < v0 * 0.6 && !blockedByPlayer {
                bot.trailing += dt
                if bot.trailing > 1.0 && blockers.prefix(playerCars).allSatisfy({ $0.distance(to: bot.position) > 700 }) {
                    bot.ignoreBots = 1.0
                    bot.trailing = 0
                    ghosts += 1
                }
            } else {
                bot.trailing = max(0, bot.trailing - dt)
            }
            // Hunters don't queue behind a car standing in the lane: they go round it
            if bot.hunt >= 0 && !bot.parked && !bot.passing && !bot.approach && gap < 110 && leaderSpeed < 15
                && bot.waiting > 0.8 && stopLine == nil && oncomingClear(bot) {
                bot.passing = true
            }
            if bot.passing {
                bot.offset = min(68, bot.offset + (bot.racer ? 120 : 40) * dt)
                // Back into the lane once the way ahead in it is clear
                var clearInLane = true
                for point in blockers.prefix(playerCars) {
                    let vx = point.x - bot.position.x, vy = point.y - bot.position.y
                    let forward = vx * cos(laneHeading) + vy * sin(laneHeading)
                    if forward > -30 && forward < 80 && abs(-vx * sin(laneHeading) + vy * cos(laneHeading)) < 40 { clearInLane = false }
                }
                if bot.racer || bot.hunt >= 0 {
                    // Back in once past what it overtook (bots too, not just players)
                    for other in bots.indices where other != index {
                        let vx = bots[other].position.x - bot.position.x, vy = bots[other].position.y - bot.position.y
                        guard abs(vx) < 120 && abs(vy) < 120 else { continue }
                        let forward = vx * cos(laneHeading) + vy * sin(laneHeading)
                        if forward > -40 && forward < 90 && abs(-vx * sin(laneHeading) + vy * cos(laneHeading)) < 40 { clearInLane = false }
                    }
                    // Something coming the other way: back in at once if there is room
                    if !oncomingClear(bot) && bot.offset > 20 && clearInLane == false { bot.offset = max(0, bot.offset - 160 * dt) }
                }
                if clearInLane && bot.offset >= 60 { bot.passing = false; bot.waiting = 0 }
            } else {
                bot.offset = max(0, bot.offset - 30 * dt)
            }
            bot.ignoreBots = max(0, bot.ignoreBots - dt)

            bot.position.x += cos(bot.heading) * bot.speed * dt
            bot.position.y += sin(bot.heading) * bot.speed * dt
            bots[index] = bot
        }
        separate(players: blockers.prefix(playerCars))
    }

    /// The lowest-numbered car of a ring of cars each waiting for the next, if `start` is in one.
    private func waitRing(from start: Int) -> Int? {
        var lowest = start
        var next = bots[start].blocker
        var hops = 0
        while next >= 0 && hops < 8 {
            if next == start { return lowest }
            lowest = min(lowest, next)
            next = bots[next].blocker
            hops += 1
        }
        return nil
    }

    private func outOfSight(_ point: CGPoint, players: ArraySlice<CGPoint>) -> Bool {
        players.allSatisfy { $0.distance(to: point) > sight }
    }

    /// Cars must never stand inside each other: any that overlap (a knocked car sliding into
    /// another, a squeeze in a junction) are pushed apart, and the one that drove in stops.
    private func separate(players: ArraySlice<CGPoint>) {
        let count = bots.count
        guard count > 1 else { return }
        for i in 0..<(count - 1) {
            for j in (i + 1)..<count {
                let dx = bots[j].position.x - bots[i].position.x
                let dy = bots[j].position.y - bots[i].position.y
                guard abs(dx) < 50 && abs(dy) < 50 else { continue }
                // A car let through out of sight is not pushed (no one can see it)
                if (bots[i].ignoreBots > 0 || bots[j].ignoreBots > 0) && outOfSight(bots[i].position, players: players) { continue }
                // A racer driving through traffic out of view is not pushed (nor does it stop)
                if (bots[i].racer && bots[i].ignoreBots > 0) || (bots[j].racer && bots[j].ignoreBots > 0),
                   players.allSatisfy({ $0.distance(to: bots[i].position) > racerFreeRange }) { continue }
                guard let push = Traffic.penetration(bots[i].box, bots[j].box) else { continue }
                overlaps += 1
                if legacy { continue }
                let movingI = bots[i].speed > 2 || bots[i].stunned > 0
                let movingJ = bots[j].speed > 2 || bots[j].stunned > 0
                let shareI: CGFloat = movingI == movingJ ? 0.5 : (movingI ? 1 : 0)
                let shareJ = 1 - shareI
                bots[i].position.x -= push.dx * shareI
                bots[i].position.y -= push.dy * shareI
                bots[j].position.x += push.dx * shareJ
                bots[j].position.y += push.dy * shareJ
                // The one heading into the other stops; a sliding one loses its slide into it
                if cos(bots[i].heading) * push.dx + sin(bots[i].heading) * push.dy > 0 { bots[i].speed = 0 }
                if cos(bots[j].heading) * push.dx + sin(bots[j].heading) * push.dy < 0 { bots[j].speed = 0 }
                for (k, sign) in [(i, CGFloat(1)), (j, CGFloat(-1))] where bots[k].stunned > 0 {
                    let length = max(hypot(push.dx, push.dy), 0.001)
                    let nx = push.dx / length * sign, ny = push.dy / length * sign
                    let into = bots[k].shove.dx * nx + bots[k].shove.dy * ny
                    if into > 0 {
                        bots[k].shove.dx -= nx * into
                        bots[k].shove.dy -= ny * into
                    }
                }
            }
        }
    }

    /// How far `b` must move (along the returned vector, `a` the other way) to stop overlapping `a`.
    static func penetration(_ a: OBB, _ b: OBB) -> CGVector? {
        let d = CGVector(dx: b.center.x - a.center.x, dy: b.center.y - a.center.y)
        var best = CGFloat.greatestFiniteMagnitude
        var bestAxis = CGVector.zero
        for axis in [a.axisU, a.axisV, b.axisU, b.axisV] {
            func reach(_ o: OBB) -> CGFloat {
                let u = o.axisU, v = o.axisV
                return o.halfSize.width * abs(u.dx * axis.dx + u.dy * axis.dy) + o.halfSize.height * abs(v.dx * axis.dx + v.dy * axis.dy)
            }
            let distance = d.dx * axis.dx + d.dy * axis.dy
            let overlap = reach(a) + reach(b) - abs(distance)
            if overlap <= 0 { return nil }
            if overlap < best {
                best = overlap
                bestAxis = distance < 0 ? CGVector(dx: -axis.dx, dy: -axis.dy) : axis
            }
        }
        return CGVector(dx: bestAxis.dx * best, dy: bestAxis.dy * best)
    }

    #if BENCHMARK
    /// The traffic check: three minutes of each city's traffic around a standing player, old
    /// drivers against new: cars inside each other, cars slipping through, how much stands still.
    static func check() -> [String] {
        var lines: [String] = []
        for (round, race) in [(0, true), (1, false), (2, true)] {
            let level = Levels.city(round: round, race: race)
            guard let map = level.city else { continue }
            let player = level.starts.first?.position ?? .zero
            for legacy in [true, false] {
                let traffic = Traffic(map: map, starts: level.bots, seed: UInt64(round * 31 + 7))
                traffic.legacy = legacy
                var stopped: CGFloat = 0
                var overlapFrames = 0
                let steps = 60 * 180
                let started = Date()
                for _ in 0..<steps {
                    let before = traffic.overlaps
                    traffic.step(1.0 / 60, blockers: [player], playerCars: 1)
                    if traffic.overlaps > before { overlapFrames += 1 }
                    stopped += traffic.stoppedShare
                }
                let ms = Date().timeIntervalSince(started) * 1000 / Double(steps)
                lines.append(String(format: "PPTRAFFIC %@ r%d %@ bots=%d overlaps=%d overlapFrames=%d slips=%d backoffs=%d stopped=%.0f%% step=%.3fms",
                                    race ? "race" : "city", round, legacy ? "old" : "new", traffic.bots.count, traffic.overlaps,
                                    overlapFrames, traffic.ghosts, traffic.backoffs, Double(stopped / CGFloat(steps) * 100), ms))
            }
        }
        // Spot Wars: when each city round's hunters take their bays (player standing at the start)
        for round in 0..<Levels.cityRounds {
            let level = Levels.city(round: round, race: false)
            guard let map = level.city else { continue }
            let traffic = Traffic(map: map, starts: level.bots, seed: UInt64((Levels.cityBase + round) * 31 + 7),
                                  spots: level.freeSpots, hunters: level.hunters)
            let player = level.starts.first?.position ?? .zero
            var times: [String] = []
            var t: CGFloat = 0
            while t < 120 && traffic.taken.count < level.freeSpots.count {
                traffic.step(1.0 / 60, blockers: [player], playerCars: 1)
                t += 1.0 / 60
                for take in traffic.takes { times.append(String(format: "s%d@%.1f", take.spot, Double(t))) }
            }
            let route = map.route(from: player, to: level.spots[0].center)
            let length = zip(route, route.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            lines.append(String(format: "PPSPOT city r%d hunters=%d spots=%d route=%.0f taken=%@",
                                round, level.hunters.count, level.freeSpots.count, Double(length), times.joined(separator: " ")))
            // Hunters still out: where they are and what they are doing
            for (index, bot) in traffic.bots.enumerated() where bot.hunt >= 0 && !bot.parked {
                let spot = level.freeSpots[bot.hunt]
                lines.append(String(format: "PPSPOT   r%d bot%d hunt=%d lane=%d>%d bay=%d>%d pos=%.0f,%.0f v=%.0f approach=%d parkT=%.2f wait=%.1f",
                                    round, index, bot.hunt, bot.from, bot.to, spot.entry, spot.exit, Double(bot.position.x), Double(bot.position.y),
                                    Double(bot.speed), bot.approach ? 1 : 0, Double(bot.parkT), Double(bot.waiting)))
            }
        }
        // Rival racers: their finish times (no player in the way)
        for round in 0..<Levels.raceRounds {
            let level = Levels.city(round: round, race: true)
            guard let map = level.city, let street = level.finishStreet else { continue }
            let traffic = Traffic(map: map, starts: level.bots, seed: UInt64((Levels.raceBase + round) * 31 + 7),
                                  racers: level.racers, finish: (a: street.a, b: street.b, point: level.spots[0].center))
            traffic.racersReleased = true
            var t: CGFloat = 0
            var slow: CGFloat = 0, crawl: CGFloat = 0, fast: CGFloat = 0, passing: CGFloat = 0
            while t < 120 && traffic.raceFinishes.count < level.racers.count {
                traffic.step(1.0 / 60, blockers: [CGPoint(x: -9999, y: -9999)], playerCars: 1)
                t += 1.0 / 60
                for bot in traffic.bots where bot.racer {
                    if bot.speed < 20 { slow += 1.0 / 60 } else if bot.speed < 150 { crawl += 1.0 / 60 } else { fast += 1.0 / 60 }
                    if bot.passing { passing += 1.0 / 60 }
                }
            }
            lines.append(String(format: "PPRACE   r%d racer-seconds: stopped=%.0f slow=%.0f fast=%.0f passing=%.0f", round,
                                Double(slow), Double(crawl), Double(fast), Double(passing)))
            let start = level.starts[0].position
            let route = map.route(from: start, to: level.spots[0].center)
            let length = zip(route, route.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            let times = traffic.raceFinishes.map { String(format: "%.1f", Double($0.time)) }.joined(separator: " ")
            let stuck = traffic.bots.filter { $0.racer }.map { String(format: "(%.0f,%.0f v%.0f)", Double($0.position.x), Double($0.position.y), Double($0.speed)) }.joined(separator: " ")
            lines.append(String(format: "PPRACE r%d racers=%d route=%.0f finishes=%@ out=%@ overlaps=%d", round, level.racers.count,
                                Double(length), times, stuck, traffic.overlaps))
        }
        // Taxi: when the rival taxis reach the customer (player standing at the start)
        for round in 0..<Levels.taxiRounds {
            let level = Levels.city(round: round, race: false, taxi: true)
            guard let map = level.city, level.taxi != nil else {
                lines.append("PPTAXI r\(round) no taxi round")
                continue
            }
            let traffic = Traffic(map: map, starts: level.bots, seed: UInt64((Levels.taxiBase + round) * 31 + 7),
                                  spots: level.freeSpots, hunters: level.hunters)
            let player = level.starts.first?.position ?? .zero
            var first = -1.0
            var t: CGFloat = 0
            while t < 120 && first < 0 {
                traffic.step(1.0 / 60, blockers: [player], playerCars: 1)
                t += 1.0 / 60
                if !traffic.takes.isEmpty { first = Double(t) }
            }
            let route = map.route(from: player, to: level.freeSpots[0].def.center)
            let length = zip(route, route.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            lines.append(String(format: "PPTAXI r%d rider=%d rivals=%d route=%.0f firstRival=%.1f", round,
                                level.taxi?.rider.rawValue ?? -1, level.hunters.count, Double(length), first))
        }
        return lines
    }
    #endif

    /// Fraction of cars standing still (for the traffic check).
    var stoppedShare: CGFloat {
        guard !bots.isEmpty else { return 0 }
        return CGFloat(bots.filter { $0.speed < 2 }.count) / CGFloat(bots.count)
    }

    /// Nothing coming the other way in the next 25 m of the oncoming lane.
    private func oncomingClear(_ bot: Bot) -> Bool {
        for other in bots {
            let vx = other.position.x - bot.position.x, vy = other.position.y - bot.position.y
            let forward = vx * cos(bot.heading) + vy * sin(bot.heading)
            let left = -vx * sin(bot.heading) + vy * cos(bot.heading)
            if forward > -20 && forward < 250 && left > 30 && left < 110 { return false }
        }
        return true
    }

    /// Compact state for the network: x, y, heading*100, from, to, speed per bot.
    func snapshot() -> [Int] {
        var result: [Int] = []
        for bot in bots {
            result += [Int(bot.position.x.rounded()), Int(bot.position.y.rounded()), Int((bot.heading * 100).rounded()),
                       bot.from, bot.to, Int(bot.speed.rounded())]
        }
        return result
    }

    /// Applies the host's state, easing toward it to hide small differences.
    func apply(_ data: [Int]) {
        guard data.count == bots.count * 6 else { return }
        for index in bots.indices {
            let base = index * 6
            let target = CGPoint(x: CGFloat(data[base]), y: CGFloat(data[base + 1]))
            let heading = CGFloat(data[base + 2]) / 100
            let from = data[base + 3]
            let to = data[base + 4]
            guard from >= 0, from < map.nodeCount, to >= 0, to < map.nodeCount else { continue }
            var bot = bots[index]
            if bot.position.distance(to: target) > 90 {
                bot.position = target
                bot.heading = heading
            } else {
                bot.position.x += (target.x - bot.position.x) * 0.6
                bot.position.y += (target.y - bot.position.y) * 0.6
                bot.heading += CGFloat.angleDelta(bot.heading, heading) * 0.6
            }
            bot.speed = CGFloat(data[base + 5])
            if from != bot.from || to != bot.to {
                bot.from = from
                bot.to = to
                let lane = map.lane(from: from, to: to)
                bot.waypoints = [lane.start, lane.end].filter {
                    ($0.x - bot.position.x) * cos(bot.heading) + ($0.y - bot.position.y) * sin(bot.heading) > 0
                }
            }
            bots[index] = bot
        }
    }
}
