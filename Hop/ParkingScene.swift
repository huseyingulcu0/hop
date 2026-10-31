import SpriteKit
import SceneKit
import UIKit

/// Game loop, input, HUD and 2D effects. The world itself is drawn in 3D by `World3D`
/// (a SceneKit view underneath this transparent SpriteKit scene).
final class ParkingScene: SKScene {

    private enum Control: Hashable {
        case left
        case right
        case forward
        case reverse
        case handbrake
    }

    private enum Phase {
        case countdown
        case driving
        case finished
    }

    private enum Gear {
        case drive
        case reverse
    }

    /// Something the car can touch: the lot edge, a level obstacle, or the other player's car.
    private enum Contact: Hashable {
        case bounds
        case obstacle(Int)
        case remoteCar
        case bot(Int)
    }

    // MARK: Configuration

    private weak var model: AppModel?
    private var world: World3D?
    private var localCar: Car3D?
    private var remoteCar: Car3D?
    private var online = false
    private var slot = 0
    private var isHost = true
    private var friendPresent = false
    private var levelIndex = 0
    private var level: LevelDef = Levels.all[0]
    private var isCity: Bool { level.city != nil }
    private var otherSlot: Int { 1 - slot }

    // MARK: Layers

    private var builtSize: CGSize = .zero
    private let fxLayer = SKNode()
    private let hud = SKNode()
    private let controlsLayer = SKNode()
    private let overlay = SKNode()

    // MARK: Nodes

    private var localTag = SKLabelNode()
    private var remoteTag = SKLabelNode()
    private var remoteCheck = SKSpriteNode()
    private var holdRing = SKShapeNode()
    private var levelLabel = SKLabelNode()
    private var timerLabel = SKLabelNode()
    private var hitsLabel = SKLabelNode()
    private var statusLabel = SKLabelNode()
    private var codeLabel = SKLabelNode()
    private var gearLabel = SKLabelNode()
    private var countdownNode = SKNode()
    private var countdownLabel = SKLabelNode()
    private var countdownShadow = SKLabelNode()
    private var menuButton = SKSpriteNode()
    private var resetButton = SKSpriteNode()
    private var soundButton = SKSpriteNode()
    private var soundIcon = SKSpriteNode()
    private var finalButton: SKNode?
    private var leftButton = SKSpriteNode()
    private var rightButton = SKSpriteNode()
    private var steerArc = SKShapeNode()
    private var steerLabel = SKLabelNode()
    private let minimap = SKNode()
    private var mapScale: CGFloat = 0.168
    private let mapRadius: CGFloat = 60
    private var mapContent = SKNode()
    private var targetPointer = SKSpriteNode()

    // Speedometer
    private var speedDial = SKNode()
    private var speedArc = SKShapeNode()
    private var speedLabel = SKLabelNode()
    private var shownSpeed: CGFloat = 0
    private var myMarker = SKShapeNode()
    private var hudLeft: CGFloat = 10
    private var routeLine = SKShapeNode()
    private var botDots: [SKNode] = []

    // Benchmark autopilot
    private let benchmark = PerfSettings.benchmark
    private var autoControls: Set<Control> = []
    private var autoReverse: CGFloat = 0
    private var stuckTime: CGFloat = 0
    private var benchClock: CGFloat = 0
    private var benchRecording = false
    private var benchDone = false
    var levelLoadMilliseconds: Double = 0
    private var finishAnimating = false
    private var finishClock: CGFloat = 0
    private var nitroFiredAt: [Double] = []
    private var detailClock: CGFloat = 0
    private var finishTestPlaced = false
    private var nitroShock = SKSpriteNode()
    private var nitroBanner = SKLabelNode()
    private var finishTestAt: Double = -1
    private var finishCrossAt: Double = -1
    /// While the results card is up the 3D world is neither updated nor drawn.
    private var worldFrozen = false
    /// False until the first level is fully loaded; the countdown waits for it.
    private var ready = false
    private var readyRequested = false
    private var navNode = SKNode()
    private var navArrow = SKSpriteNode()
    private var navLabel = SKLabelNode()

    // City traffic and race
    private var traffic: Traffic?
    // Spot Wars: the free bay we are heading for, its pins on the map, the bays-left chip, and
    // which traffic cars show hazard lights
    private var spotWars: Bool { isCity && !level.race && !level.freeSpots.isEmpty && level.taxi == nil }
    private var spotTarget = -1
    private var freeSpotPins: [SKNode] = []
    private var spotsChip = SKNode()
    private var hunterHazard: [Bool] = []
    private var spotsGoneFailed = false
    private var botCars: [Car3D] = []
    private var botSendClock: TimeInterval = 0
    private var routeClock: CGFloat = 0
    private var route: [CGPoint] = []
    private var giveUp: CGFloat = 20
    private var myWins = 0
    private var friendWins = 0
    /// This series started with the friend: a best-of-three match.
    private var onlineMatch = false
    /// Two rounds won, or all three played.
    private var matchOver: Bool {
        myWins >= Levels.onlineWinsNeeded || friendWins >= Levels.onlineWinsNeeded
            || Levels.isLast(levelIndex, online: true)
    }
    private var friendMarker = SKShapeNode()
    private var northMarker = SKLabelNode()
    private var policeMarker = SKShapeNode()
    private var gasPedal = SKSpriteNode()
    private var hornButton = SKSpriteNode()

    // Nitro
    private var nitro: CGFloat = 0.5          // tank 0...1
    private var boostTime: CGFloat = 0        // seconds of boost left
    private var boostVisual: CGFloat = 0      // eased 0...1 for effects
    private var remoteBoost = false
    private var boostDuration: CGFloat = 3.0
    private var nitroFillTime: CGFloat = 10
    /// Nitro push (units/s²) for the chosen car.
    private var nitroPush: CGFloat = 300
    private var nitroButton = SKSpriteNode()
    private var nitroIcon = SKSpriteNode()
    private var nitroRing = SKShapeNode()
    private var speedLines: [(sprite: SKSpriteNode, angle: CGFloat, radius: CGFloat)] = []
    private var boostTint = SKSpriteNode()
    private var isBoosting: Bool { boostTime > 0 }
    private var lastHorn: TimeInterval = -10
    private var newBest = false
    /// How precisely the car stood in its bay (solo parking levels), measured as it parked.
    private var lastPrecision: ParkPrecision?
    private var precisionBest = false
    private let advanceDelay: TimeInterval = 4.5
    private var reversePedal = SKSpriteNode()
    private var activeTouches: [UITouch: Control] = [:]
    private var wheelStartX: [UITouch: CGFloat] = [:]
    private var dotTexture = SKTexture()

    // MARK: Driving model (1 world unit ≈ 10 cm)

    private let wheelBase: CGFloat = 26
    private var maxSteer: CGFloat = 0.64
    private var steerRate: CGFloat = 2.6
    private var engineAccel: CGFloat = 150
    private let reverseAccel: CGFloat = 95
    private let brakeDecel: CGFloat = 360
    private let rolling: CGFloat = 22
    private let airDrag: CGFloat = 0.22
    private var maxForward: CGFloat = 150
    private let maxReverse: CGFloat = 70
    private let creepSpeed: CGFloat = 12

    // Ghost: the player's best run of a solo level, replayed as a see-through car
    private var ghostRecording: [Float] = []
    private var ghostReplay: [Float] = []
    private var ghostCar: Car3D?
    private let ghostStep: TimeInterval = 0.1

    static let slowCountdown = ProcessInfo.processInfo.arguments.contains("-slowcountdown")
    static let failTest = PerfSettings.benchmark && ProcessInfo.processInfo.arguments.contains("-failtest")
    static let policeTest = PerfSettings.benchmark && ProcessInfo.processInfo.arguments.contains("-policetest")
    static let cardTest = PerfSettings.benchmark && ProcessInfo.processInfo.arguments.contains("-cardtest")
    static let parkedTest = PerfSettings.benchmark && ProcessInfo.processInfo.arguments.contains("-parkedtest")
    /// Online check (benchmark builds, two simulators in one room): the guest drives into the host.
    static let netRole: String? = {
        guard PerfSettings.benchmark else { return nil }
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-nethost") ? "host" : (args.contains("-netjoin") ? "join" : nil)
    }()
    private var netLogClock: CGFloat = 0

    private func netLog(_ text: String) {
        FileHandle.standardError.write("PPNET \(text)\n".data(using: .utf8)!)
    }

    /// The guest steers at the host's car (as it sees it) at full throttle; the host waits. Logs
    /// the measured delay and how far apart the cars are every two seconds.
    private func netTestDrive(_ role: String, _ dt: CGFloat) {
        autoControls = []
        guard phase == .driving, !localParked else { return }
        netLogClock += dt
        if netLogClock > 2 {
            netLogClock = 0
            netLog(String(format: "%@ delay=%.0fms friend=%@ seen=%.0f speed=%.0f path=%@", role, oneWayDelay * 1000,
                          friendPresent ? "yes" : "no", carPosition.distance(to: remotePosition), velocity,
                          model?.net.fastActive == true ? "udp" : "ws"))
        }
        guard role == "join", friendPresent, remoteTarget != nil else { return }
        let relative = CGFloat.angleDelta(heading, atan2(remotePosition.y - carPosition.y, remotePosition.x - carPosition.x))
        autoControls = relative > 0.08 ? [.forward, .left] : (relative < -0.08 ? [.forward, .right] : [.forward])
    }
    private var policeTestDone = false

    /// Best-run ghost car on solo parking levels (turned off).
    static let ghostEnabled = false

    private func setupGhost() {
        ghostCar?.node.removeFromParentNode()
        ghostCar = nil
        ghostRecording.removeAll()
        ghostReplay = []
        // Off: the grey best-run copy confused players. Old recordings are cleared.
        guard ParkingScene.ghostEnabled else {
            UserDefaults.standard.removeObject(forKey: "pp.ghost.\(levelIndex)")
            return
        }
        guard !isCity, !online, !benchmark, let world = world else { return }
        ghostReplay = UserDefaults.standard.array(forKey: "pp.ghost.\(levelIndex)") as? [Float] ?? []
        guard ghostReplay.count >= 6 else { return }
        let choice = model?.carChoice ?? CarChoice.defaultChoice
        let car = world.makeCar(color: UIColor(white: 0.95, alpha: 1), style: .racer, model: choice.model)
        car.node.opacity = 0.32
        car.node.enumerateHierarchy { node, _ in node.castsShadow = false }
        ghostCar = car
        car.update(position: CGPoint(x: CGFloat(ghostReplay[0]), y: CGFloat(ghostReplay[1])), heading: CGFloat(ghostReplay[2]),
                   steer: 0, braking: false, reversing: false)
    }

    /// Records this run every 0.1 s and moves the ghost along the best run at the same time.
    private func updateGhost() {
        let sample = Int(elapsed / ghostStep)
        if ParkingScene.ghostEnabled && !isCity && !online && ghostRecording.count / 3 <= sample && ghostRecording.count < 3 * 1800 {
            ghostRecording += [Float(carPosition.x), Float(carPosition.y), Float(heading)]
        }
        guard let car = ghostCar else { return }
        let frames = ghostReplay.count / 3
        let t = elapsed / ghostStep
        let i = min(frames - 1, Int(t))
        let j = min(frames - 1, i + 1)
        let k = Float(t - Double(i))
        func value(_ frame: Int, _ part: Int) -> Float { ghostReplay[frame * 3 + part] }
        let x = value(i, 0) + (value(j, 0) - value(i, 0)) * k
        let y = value(i, 1) + (value(j, 1) - value(i, 1)) * k
        let heading = CGFloat(value(i, 2)) + CGFloat.angleDelta(CGFloat(value(i, 2)), CGFloat(value(j, 2))) * CGFloat(k)
        car.update(position: CGPoint(x: CGFloat(x), y: CGFloat(y)), heading: heading, steer: 0, braking: false, reversing: false)
        if i >= frames - 1 && car.node.action(forKey: "gone") == nil {
            car.node.runAction(.fadeOut(duration: 0.6), forKey: "gone")
        }
    }

    private func saveGhost() {
        guard ParkingScene.ghostEnabled, !isCity, !online, ghostRecording.count >= 6 else { return }
        ghostRecording += [Float(carPosition.x), Float(carPosition.y), Float(heading)]
        UserDefaults.standard.set(ghostRecording, forKey: "pp.ghost.\(levelIndex)")
    }

    // What this round earned (paid as coins at the end)
    private var runDriftPoints = 0
    private var runNearMisses = 0
    private var runEscapes = 0
    private var runTopSpeed = 0

    // Gearbox: gives the engine its rising and falling note and the pull its steps
    private var gearIndex = 1
    private var rpm: CGFloat = 900
    private var shiftCut: CGFloat = 0
    private var lastThrottle = false
    private let idleRPM: CGFloat = 900
    private let redline: CGFloat = 7000
    /// Top speed of each gear as a share of the car's top speed (5th only with nitro).
    private let gearTops: [CGFloat] = [0.3, 0.52, 0.75, 1.08, 1.8]
    /// Sideways force the tyres hold before the car runs wide (raised by the grip upgrade).
    private var lateralGrip: CGFloat = 420
    /// How far the tyres are past their grip in a corner (0...1).
    private var understeer: CGFloat = 0
    /// Share of the tyres' sideways grip in use (1 = at the limit).
    private var gripUse: CGFloat = 0
    /// Smoothed tyre squeal (0...1).
    private var squealLevel: CGFloat = 0
    /// On a wet or snowy road at speed the body slides out of line: the angle between where the
    /// car points and where it travels (0 on a dry road and in a drift, which has its own).
    private var skid: CGFloat = 0
    /// Kerbs: the body's height on its springs (metres) and how fast it moves, and its tilt
    /// from the wheels standing at different heights.
    private var suspension = Suspension()
    private var frontKerb: CGFloat = 0
    private var rearKerb: CGFloat = 0

    private var carPosition = CGPoint.zero
    private var heading: CGFloat = 0
    private var velocity: CGFloat = 0
    private var steer: CGFloat = 0
    private var wheelInput: CGFloat = 0
    private var gear: Gear = .drive
    private var engaged = false
    private var braking = false
    private var longitudinalAccel: CGFloat = 0
    private var lateralAccel: CGFloat = 0
    private var skidClock: CGFloat = 0
    private var smokeClock: CGFloat = 0
    private var obstacleBoxes: [OBB] = []
    /// What makes this parking level harder than the last one (Challenge.swift).
    private var challenge = ParkChallenge.easy
    private var patrolCars: [PatrolCar] = []
    private var patrolBoxStart = 0
    private var patrolHornAt: TimeInterval = -10
    private var failReason: String?
    private var lastHitWarned = false
    private let challengeCard = SKNode()

    // Remote car
    private var remotePosition = CGPoint.zero
    private var remoteHeading: CGFloat = 0
    private var remoteSteer: CGFloat = 0
    private var remoteBraking = false
    private var remoteReversing = false
    private var remoteTarget: (CGPoint, CGFloat)?

    /// Received states of the other car, timed by the sender's clock, played back slightly in
    /// the past so there are always two states to blend between (smooth despite network jitter).
    private struct RemoteSnapshot {
        let time: TimeInterval
        let position: CGPoint
        let heading: CGFloat
        let velocity: CGFloat
        /// The sender's own turn rate and acceleration (smoothed there), when it sends them.
        var yawRate: CGFloat? = nil
        var accel: CGFloat? = nil
    }
    private var remoteSnapshots: [RemoteSnapshot] = []
    /// Smoothed turn rate and acceleration used to carry the friend's car ahead.
    private var remoteYawRate: CGFloat = 0
    private var remoteAccel: CGFloat = 0
    /// Our own smoothed turn rate, sent with each state.
    private var sentYawRate: CGFloat = 0
    private var yawRateHeading: CGFloat?
    private var clockOffset: TimeInterval?
    /// States arrive 30 times a second; played back this late they always have one on each side.
    /// Played back this late; shorter over the UDP-like path (states come 60 times a second and
    /// never queue up behind a lost one), so less has to be predicted.
    private var interpolationDelay: TimeInterval { model?.net.fastActive == true ? 0.06 : 0.1 }

    // MARK: Level state

    private var phase: Phase = .countdown
    private var countdown: CGFloat = 3
    private var elapsed: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0
    private var sendClock: TimeInterval = 0
    /// Network delay to the friend (half the round trip of a "pi"/"po" echo), measured every
    /// two seconds; the friend's car is drawn this much (plus the interpolation delay) ahead of
    /// its last state, so it is where the friend really is and a hit lands where it is seen.
    private var oneWayDelay: TimeInterval = 0.06
    private var pingClock: TimeInterval = 0
    /// When the friend's last hit on us arrived (our own detection of the same crash is skipped).
    private var hitByFriendAt: TimeInterval = -10
    /// The friend's computed pose last frame (the drawn pose keeps a fading offset from it).
    private var remotePoseLast: (CGPoint, CGFloat)?
    private var hits = 0
    private var lastHitAt: TimeInterval = -10
    // Drift: the car can point away from where it travels; points turn into nitro
    private var travelHeading: CGFloat = 0
    /// Turn rate of the body (rad/s); has inertia while drifting.
    private var yawSpeed: CGFloat = 0
    /// Which way the tail went out (+1: car turning left), and how long the slide has been small.
    private var driftSide: CGFloat = 1
    private var driftCalm: CGFloat = 0
    private var drifting = false
    /// Arcade drift (as in Asphalt): the angle the car holds to its line, eased toward a target
    private var driftSlip: CGFloat = 0
    /// Letting go: the angle eases back to straight before the drift ends
    private var driftExiting = false
    private var driftCounter: CGFloat = 0
    private var driftScore: CGFloat = 0
    private var driftClock: CGFloat = 0
    private var lastDriftEnd: TimeInterval = -10
    private var lastDriftScore: CGFloat = 0
    private var driftSmokeClock: CGFloat = 0
    private var driftButton = SKSpriteNode()
    private var driftLabel = SKLabelNode()
    private var shownDriftPoints = -1
    // Jumps off the alley ramps
    private var airTime: CGFloat = 0
    private var airDuration: CGFloat = 0
    private var airPeak: CGFloat = 0
    private var rampCooldown: TimeInterval = -10
    // Near misses, loose props, police
    private var nearMissAt: [Int: TimeInterval] = [:]
    private var streetProps: StreetProps?
    private var police: PoliceChase?
    private var trail: [CGPoint] = []
    private var trailClock: CGFloat = 0
    /// Last drawn HUD values (shapes and labels only change when these do).
    private var shownNitroStep = -2
    private var shownSteerStep = -999
    private var shownSpeedStep = -2
    private var lastShownKmh = -1
    /// Pre-drawn letters of the finish titles.
    private var finishGlyphs: [String: [(texture: SKTexture, advance: CGFloat)]] = [:]
    /// Crash reaction (arcade racers): a shove away from what we hit and a spin that fade out.
    private var crashShove = CGVector.zero
    private var crashSpin: CGFloat = 0
    private var parkHold: CGFloat = 0
    private var localParked = false
    private var localTime: Double = 0
    /// Seconds since we finished while the friend is still driving; after a moment the camera
    /// follows their car so we watch them instead of waiting.
    private var spectateClock: CGFloat = 0
    /// The rival's speed (world units/s), from their position updates, for the TV cameras.
    private var spectateSpeed: CGFloat = 0
    private var spectateLast: CGPoint?
    /// Broadcast look while spectating: letterbox bars, a live tag and a quick dip at each cut.
    private var spectateOverlay: SKNode?
    private var remoteParked = false
    private var remoteTime: Double = 0
    private var remoteHits = 0
    private var resultsShown = false
    /// This round's win is in the score (a card shown again must not count it twice).
    private var roundCounted = false
    private var advanceScheduled = false

    // MARK: Haptics and sound

    private lazy var bumpHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private lazy var tickHaptic = UIImpactFeedbackGenerator(style: .light)
    private lazy var notifyHaptic = UINotificationFeedbackGenerator()
    private var audio: AudioManager { AudioManager.shared }

    // MARK: Setup

    func configure(model: AppModel, world: World3D, online: Bool, slot: Int, isHost: Bool, level: Int) {
        self.model = model
        self.world = world
        self.online = online
        self.slot = online ? slot : 0
        self.isHost = isHost
        self.friendPresent = online
        self.levelIndex = Levels.clamp(level)
        let mine = model.carChoice
        localCar = world.makeCar(color: mine.color, style: .racer, model: mine.model)
        localCar?.setRim(mine.rimColor)
        let friend = model.friendCar ?? CarChoice.friendDefault
        // Solo: the friend's car stays hidden, so its 4K maps are not even read
        remoteCar = world.makeCar(color: friend.color, style: .racer, model: friend.model, textures: online)
        remoteCar?.setRim(friend.rimColor)
        remoteChoice = friend
        // The chosen car's driving character with its upgrades (online too: every bought level
        // counts). Race and city rounds use the full top speed; parking levels a calmer 80 %.
        let spec = mine.spec
        let perf = CarPerformance.of(spec, upgrades: Progression.upgrades(for: mine.model))
        let open = Levels.isRace(levelIndex) || Levels.isCity(levelIndex)
        maxForward = perf.topKmh / 0.36 * (open ? 1 : 0.8)
        engineAccel = maxForward * perf.acceleration
        maxSteer = 0.64 * min(1.15, perf.handling)
        steerRate = 2.6 * perf.handling
        lateralGrip = 420 * perf.handling
        nitroPush = 300 * perf.nitroPower * (open ? 1 : 0.8)
        nitroFillTime = 10 * perf.nitroFill
    }

    private var remoteChoice = CarChoice.friendDefault

    /// The friend picked another car (their choice can arrive after the world is built).
    func friendCarChanged() {
        guard let world = world, let choice = model?.friendCar, choice != remoteChoice else { return }
        remoteChoice = choice
        let hidden = remoteCar?.isHidden ?? true
        remoteCar?.node.removeFromParentNode()
        remoteCar = world.makeCar(color: choice.color, style: .racer, model: choice.model)
        remoteCar?.setRim(choice.rimColor)
        remoteCar?.isHidden = hidden
    }

    override func didMove(to view: SKView) {
        stage("scene attached \(Int(size.width))x\(Int(size.height))")
        LeakWatch.track(view, "SKView")
        view.isMultipleTouchEnabled = true
        view.allowsTransparency = true
        backgroundColor = .clear
        audio.ensureRunning()
        audio.setMusicVolume(0.18)
        buildIfNeeded()
    }

    override func willMove(from view: SKView) {
        audio.setMotor(active: false, rpm: 0, load: 0)
        audio.setMusicVolume(0.5)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        buildIfNeeded()
    }

    private func buildIfNeeded() {
        guard view != nil, size.width > 1, size.height > 1, size != builtSize else { return }
        builtSize = size
        build()
    }

    private var insets: UIEdgeInsets { view?.safeAreaInsets ?? .zero }

    private func build() {
        stage("build")
        removeAllChildren()
        for layer in [fxLayer, hud, controlsLayer, overlay] {
            layer.removeAllChildren()
            layer.removeAllActions()
        }
        activeTouches.removeAll()
        wheelStartX.removeAll()

        addChild(fxLayer)
        addChild(hud)
        addChild(controlsLayer)
        addChild(overlay)
        fxLayer.zPosition = 50
        hud.zPosition = 100
        controlsLayer.zPosition = 110
        overlay.zPosition = 200

        world?.fit(size: size, insets: insets, topReserved: 50)
        dotTexture = CarArt.dot()
        // The parked ticket and its stamp are drawn now, not on the frame the car parks
        _ = CarArt.parkTicket(size: CGSize(width: 340, height: 190), stub: 62)
        _ = CarArt.stamp(Strings.upper(Strings.parkedBig.replacingOccurrences(of: "!", with: "")),
                         color: UIColor(red: 0.08, green: 0.6, blue: 0.32, alpha: 1), fontSize: 17)

        let vignette = SKSpriteNode(texture: CarArt.vignette(size: size))
        vignette.size = size
        vignette.position = CGPoint(x: size.width / 2, y: size.height / 2)
        vignette.alpha = 0.55
        vignette.zPosition = 40
        addChild(vignette)

        localTag = makeLabel(Strings.you, size: 12, color: .white)
        localTag.isHidden = true
        fxLayer.addChild(localTag)
        remoteTag = makeLabel(Strings.friend, size: 12, color: UIColor.white.withAlphaComponent(0.85))
        fxLayer.addChild(remoteTag)
        remoteCheck = SKSpriteNode(texture: CarArt.symbol("checkmark.circle.fill", pointSize: 28,
                                                          color: UIColor(red: 0.4, green: 1, blue: 0.6, alpha: 1)))
        remoteCheck.size = CGSize(width: 24, height: 24)
        fxLayer.addChild(remoteCheck)

        holdRing = SKShapeNode()
        holdRing.strokeColor = UIColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1)
        holdRing.lineWidth = 4
        holdRing.lineCap = .round
        holdRing.glowWidth = 2
        fxLayer.addChild(holdRing)

        buildHUD()
        buildControls()
        // Render the big banner fonts once so the first NITRO!/FINISH! does not stall a frame
        for (text, fontSize) in [(Strings.nitroGo, CGFloat(34)), (Strings.finishBig, CGFloat(76)), ("0123456789.s", CGFloat(22))] {
            let warm = makeLabel(text, size: fontSize, color: .white)
            warm.alpha = 0.01
            warm.position = CGPoint(x: size.width / 2, y: size.height / 2)
            hud.addChild(warm)
            warm.run(.sequence([.wait(forDuration: 0.5), .removeFromParent()]))
        }
        load(level: levelIndex)
    }

    private func makeLabel(_ text: String, size fontSize: CGFloat, color: UIColor, font: String = "Barlow-ExtraBold") -> SKLabelNode {
        let label = SKLabelNode(fontNamed: font)
        label.text = text
        label.fontSize = fontSize
        label.fontColor = color
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        return label
    }

    private func makeGlass(width: CGFloat, height: CGFloat, corner: CGFloat? = nil) -> SKSpriteNode {
        let glass = SKSpriteNode(texture: CarArt.glass(size: CGSize(width: width, height: height), corner: corner ?? height / 2))
        glass.size = CGSize(width: width, height: height)
        return glass
    }

    private func makeIcon(_ name: String, size: CGFloat, color: UIColor = .white) -> SKSpriteNode {
        let texture = CarArt.symbol(name, pointSize: size * 1.6, color: color)
        let icon = SKSpriteNode(texture: texture)
        let textureSize = texture.size()
        let aspect = textureSize.height > 0 ? textureSize.width / textureSize.height : 1
        icon.size = CGSize(width: size * aspect, height: size)
        return icon
    }

    private func buildHUD() {
        let top = size.height - 24
        let left = max(insets.left, 10)
        let right = max(insets.right, 10)

        menuButton = makeGlass(width: 40, height: 40)
        menuButton.position = CGPoint(x: left + 24, y: top)
        menuButton.addChild(makeIcon("xmark", size: 15))
        hud.addChild(menuButton)

        resetButton = makeGlass(width: 40, height: 40)
        resetButton.position = CGPoint(x: left + 70, y: top)
        resetButton.addChild(makeIcon("arrow.counterclockwise", size: 17))
        hud.addChild(resetButton)

        soundButton = makeGlass(width: 40, height: 40)
        soundButton.position = CGPoint(x: left + 116, y: top)
        hud.addChild(soundButton)
        refreshSoundIcon()

        let center = makeGlass(width: 330, height: 38)
        center.position = CGPoint(x: size.width / 2 + 40, y: top)
        hud.addChild(center)
        topBar = center
        levelLabel = makeLabel("", size: 14, color: .white, font: "Barlow-Bold")
        levelLabel.horizontalAlignmentMode = .left
        levelLabel.position = CGPoint(x: -150, y: 0)
        center.addChild(levelLabel)
        let stopwatch = makeIcon("stopwatch.fill", size: 15, color: UIColor(red: 1, green: 0.82, blue: 0.36, alpha: 1))
        stopwatch.position = CGPoint(x: 92, y: 0)
        center.addChild(stopwatch)
        timerLabel = makeLabel("0.0", size: 16, color: UIColor(red: 1, green: 0.86, blue: 0.45, alpha: 1))
        timerLabel.horizontalAlignmentMode = .left
        timerLabel.position = CGPoint(x: 104, y: 0)
        center.addChild(timerLabel)

        let bumps = makeGlass(width: 84, height: 38)
        bumps.position = CGPoint(x: size.width - right - 46, y: top)
        hud.addChild(bumps)
        let warning = makeIcon("exclamationmark.triangle.fill", size: 15, color: UIColor(red: 1, green: 0.62, blue: 0.30, alpha: 1))
        warning.position = CGPoint(x: -18, y: 0)
        bumps.addChild(warning)
        hitsLabel = makeLabel("0", size: 17, color: .white)
        hitsLabel.position = CGPoint(x: 12, y: 0)
        bumps.addChild(hitsLabel)

        codeLabel = makeLabel("", size: 11, color: UIColor.white.withAlphaComponent(0.85), font: "Barlow-Bold")
        codeLabel.position = CGPoint(x: size.width - right - 46, y: top - 30)
        hud.addChild(codeLabel)

        hudTop = top
        statusLabel = makeLabel("", size: 16, color: .white)
        statusLabel.position = CGPoint(x: size.width / 2 + 40, y: top - 52)
        hud.addChild(statusLabel)

        minimap.removeAllChildren()
        hudLeft = left
        hud.addChild(minimap)
        buildSpeedometer(left: left, top: top)

        // The turn guidance lives in the top bar (in place of the level name while driving in the
        // city), so nothing hangs below the bar over the road ahead
        navNode = SKNode()
        navNode.position = center.position
        let arrowDisc = SKShapeNode(circleOfRadius: 12)
        arrowDisc.fillColor = UIColor(red: 1.0, green: 0.78, blue: 0.10, alpha: 1)
        arrowDisc.strokeColor = .clear
        arrowDisc.position = CGPoint(x: -146, y: 0)
        navNode.addChild(arrowDisc)
        navArrow = makeIcon("arrow.up", size: 14, color: UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1))
        navArrow.position = arrowDisc.position
        navNode.addChild(navArrow)
        navLabel = makeLabel("", size: 14, color: .white)
        navLabel.horizontalAlignmentMode = .left
        navLabel.position = CGPoint(x: -128, y: 0)
        navNode.addChild(navLabel)
        navNode.isHidden = true
        hud.addChild(navNode)

        // The count: one big slanted number up the road ahead (well above the car, below the top
        // bar), nothing else. Each number slams in; GO is green and lifts away at once.
        countdownNode = SKNode()
        countdownNode.position = countdownHome
        countdownNode.zPosition = 5
        countdownShadow = makeLabel("", size: 118, color: UIColor(white: 0, alpha: 0.28), font: "BarlowCondensed-BlackItalic")
        countdownShadow.position = CGPoint(x: 0, y: -5)
        countdownNode.addChild(countdownShadow)
        countdownLabel = makeLabel("", size: 118, color: .white, font: "BarlowCondensed-BlackItalic")
        countdownNode.addChild(countdownLabel)
        countdownCaption = makeLabel("", size: 1, color: .clear)
        countdownLamps = []
        startLamps = []
        // (the old fill bar, kept off screen)
        countdownBar = SKSpriteNode(color: .clear, size: CGSize(width: 1, height: 1))
        hud.addChild(countdownNode)

        // Hold module: the same capsule, shown while the car sits in its bay: what to do in two
        // words and a bar that fills to the park
        holdModule = SKNode()
        holdModule.position = holdHome
        holdModule.zPosition = 6
        holdModule.addChild(makeGlass(width: 196, height: 46))
        holdLabel = makeLabel(Strings.hold.localUpper, size: 13, color: .white, font: "Barlow-ExtraBold")
        holdLabel.position = CGPoint(x: 0, y: 6)
        holdModule.addChild(holdLabel)
        let holdTrack = SKSpriteNode(color: UIColor(white: 1, alpha: 0.14), size: CGSize(width: 156, height: 4))
        holdTrack.position = CGPoint(x: 0, y: -11)
        holdModule.addChild(holdTrack)
        holdFill = SKSpriteNode(color: UIColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1), size: CGSize(width: 156, height: 4))
        holdFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        holdFill.position = CGPoint(x: -78, y: 0)
        holdFill.xScale = 0.001
        holdTrack.addChild(holdFill)
        holdModule.alpha = 0
        hud.addChild(holdModule)
    }

    /// The count: up the road ahead, between the top bar and the car.
    private var countdownHome: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.64) }
    /// The gantry's lamps, by column (two each).
    private var startLamps: [[SKSpriteNode]] = []
    private var countdownCaption = SKLabelNode()
    /// The count on show (3, 2, 1; 0 for GO).
    private var countdownStep = 3
    /// The top bar (level and timer); it steps aside while the start lights grow out of it.
    private var topBar = SKNode()
    /// The hold capsule: under the top bar and the rules chip, well above the car.
    private var holdHome: CGPoint { CGPoint(x: size.width / 2 + 40, y: size.height - 124) }
    private var countdownLamps: [SKShapeNode] = []
    private var holdModule = SKNode()
    private var holdLabel = SKLabelNode()
    private var holdFill = SKSpriteNode()
    private var holdShown = false
    private var countdownBar = SKSpriteNode()
    private var countdownColor = UIColor.white

    private func refreshSoundIcon() {
        soundIcon.removeFromParent()
        soundIcon = makeIcon(audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 15)
        soundButton.addChild(soundIcon)
    }

    private func buildControls() {
        let left = max(insets.left, 12)
        let right = max(insets.right, 12)

        let steerSize = CGSize(width: 82, height: 82)
        let steerAccent = UIColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1)
        leftButton = SKSpriteNode(texture: CarArt.pedal(size: steerSize, accent: steerAccent))
        leftButton.size = steerSize
        leftButton.position = CGPoint(x: left + steerSize.width / 2 + 8, y: steerSize.height / 2 + 14)
        controlsLayer.addChild(leftButton)
        let leftIcon = makeIcon("arrowtriangle.left.fill", size: 28)
        leftIcon.position = CGPoint(x: -2, y: 4)
        leftButton.addChild(leftIcon)
        rightButton = SKSpriteNode(texture: CarArt.pedal(size: steerSize, accent: steerAccent))
        rightButton.size = steerSize
        rightButton.position = CGPoint(x: leftButton.position.x + steerSize.width + 12, y: leftButton.position.y)
        controlsLayer.addChild(rightButton)
        let rightIcon = makeIcon("arrowtriangle.right.fill", size: 28)
        rightIcon.position = CGPoint(x: 2, y: 4)
        rightButton.addChild(rightIcon)

        // Bar above the buttons showing how far the front wheels are turned
        let barCenter = CGPoint(x: (leftButton.position.x + rightButton.position.x) / 2, y: leftButton.position.y + steerSize.height / 2 + 16)
        let track = SKShapeNode(rect: CGRect(x: -80, y: -3.5, width: 160, height: 7), cornerRadius: 3.5)
        track.fillColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 0.55)
        track.strokeColor = UIColor.white.withAlphaComponent(0.2)
        track.position = barCenter
        // The steering bar is no longer shown (a calmer HUD); its nodes stay for the gauge code
        _ = track
        let tick = SKShapeNode(rect: CGRect(x: -1, y: -6, width: 2, height: 12))
        tick.fillColor = UIColor.white.withAlphaComponent(0.6)
        tick.strokeColor = .clear
        tick.position = barCenter
        steerArc = SKShapeNode()
        steerArc.fillColor = UIColor(red: 1.0, green: 0.78, blue: 0.10, alpha: 1)
        steerArc.strokeColor = .clear
        steerArc.position = barCenter
        steerLabel = makeLabel("", size: 12, color: UIColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1))
        steerLabel.position = CGPoint(x: barCenter.x, y: barCenter.y + 16)

        let gasSize = CGSize(width: 68, height: 116)
        gasPedal = SKSpriteNode(texture: CarArt.pedal(size: gasSize, accent: UIColor(red: 0.30, green: 0.85, blue: 0.50, alpha: 1)))
        gasPedal.size = gasSize
        gasPedal.position = CGPoint(x: size.width - right - gasSize.width / 2 - 6, y: gasSize.height / 2 + 14)
        controlsLayer.addChild(gasPedal)
        let gasIcon = makeIcon("arrow.up", size: 18)
        gasIcon.position = CGPoint(x: 0, y: 6)
        gasPedal.addChild(gasIcon)
        let gasText = makeLabel(Strings.forward, size: 10, color: UIColor.white.withAlphaComponent(0.85))
        gasText.position = CGPoint(x: 0, y: -18)
        gasPedal.addChild(gasText)

        let reverseSize = CGSize(width: 68, height: 84)
        reversePedal = SKSpriteNode(texture: CarArt.pedal(size: reverseSize, accent: UIColor(red: 1.0, green: 0.38, blue: 0.32, alpha: 1)))
        reversePedal.size = reverseSize
        reversePedal.position = CGPoint(x: gasPedal.position.x - gasSize.width / 2 - reverseSize.width / 2 - 12,
                                        y: reverseSize.height / 2 + 14)
        controlsLayer.addChild(reversePedal)
        let reverseIcon = makeIcon("arrow.down", size: 16)
        reverseIcon.position = CGPoint(x: 0, y: 2)
        reversePedal.addChild(reverseIcon)
        let reverseText = makeLabel(Strings.reverse, size: 10, color: UIColor.white.withAlphaComponent(0.85))
        reverseText.position = CGPoint(x: 0, y: -20)
        reversePedal.addChild(reverseText)

        hornButton = makeGlass(width: 60, height: 60)
        hornButton.position = CGPoint(x: gasPedal.position.x, y: gasPedal.position.y + gasSize.height / 2 + 38)
        controlsLayer.addChild(hornButton)
        let hornIcon = makeIcon("horn.blast.fill", size: 20, color: UIColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1))
        hornIcon.position = CGPoint(x: 0, y: 6)
        hornButton.addChild(hornIcon)
        let hornText = makeLabel(Strings.horn, size: 9, color: UIColor.white.withAlphaComponent(0.85))
        hornText.position = CGPoint(x: 0, y: -15)
        hornButton.addChild(hornText)

        nitroButton = makeGlass(width: 70, height: 70)
        nitroButton.position = CGPoint(x: reversePedal.position.x - reverseSize.width / 2 - 52, y: 50)
        controlsLayer.addChild(nitroButton)
        let nitroTrack = SKShapeNode(circleOfRadius: 39)
        nitroTrack.strokeColor = UIColor.white.withAlphaComponent(0.18)
        nitroTrack.lineWidth = 5
        nitroTrack.fillColor = .clear
        nitroButton.addChild(nitroTrack)
        nitroRing = SKShapeNode()
        nitroRing.strokeColor = UIColor(red: 0.30, green: 0.85, blue: 1.0, alpha: 1)
        nitroRing.lineWidth = 5
        nitroRing.lineCap = .round
        nitroRing.glowWidth = 2
        nitroButton.addChild(nitroRing)
        nitroIcon = makeIcon("flame.fill", size: 24, color: UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1))
        nitroIcon.position = CGPoint(x: 0, y: 7)
        nitroButton.addChild(nitroIcon)
        let nitroText = makeLabel(Strings.nitro, size: 10, color: .white)
        nitroText.position = CGPoint(x: 0, y: -17)
        nitroButton.addChild(nitroText)

        // Handbrake for drifts, above the nitro button
        driftButton = makeGlass(width: 64, height: 64)
        driftButton.position = CGPoint(x: nitroButton.position.x, y: nitroButton.position.y + 84)
        controlsLayer.addChild(driftButton)
        let driftIcon = makeIcon("car.rear.and.tire.marks", size: 20, color: UIColor(red: 1.0, green: 0.55, blue: 0.25, alpha: 1))
        driftIcon.position = CGPoint(x: 0, y: 6)
        driftButton.addChild(driftIcon)
        let driftText = makeLabel(Strings.driftButton, size: 9, color: .white)
        driftText.position = CGPoint(x: 0, y: -16)
        driftButton.addChild(driftText)
        driftLabel = makeLabel("", size: 26, color: UIColor(red: 1.0, green: 0.62, blue: 0.2, alpha: 1))
        driftLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.8)
        driftLabel.alpha = 0.002
        driftLabel.zPosition = 20
        hud.addChild(driftLabel)

        // Screen effects for the boost
        speedLines.removeAll()
        for _ in 0..<30 {
            let line = SKSpriteNode(texture: CarArt.speedLineTexture)
            line.size = CGSize(width: 3, height: 110)
            line.color = UIColor(red: 0.75, green: 0.92, blue: 1.0, alpha: 1)
            line.colorBlendFactor = 0.6
            line.blendMode = .add
            line.alpha = 0.002
            line.zPosition = 45
            addChild(line)
            speedLines.append((line, CGFloat.random(in: 0...(2 * CGFloat.pi)), CGFloat.random(in: 0...size.width * 0.6)))
        }
        boostTint = SKSpriteNode(texture: CarArt.vignette(size: size))
        boostTint.size = size
        boostTint.position = CGPoint(x: size.width / 2, y: size.height / 2)
        boostTint.color = UIColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1)
        boostTint.colorBlendFactor = 1
        // Effects rest at a nearly invisible alpha instead of 0: SpriteKit skips fully transparent
        // nodes, so their blend pipelines would otherwise be set up on the first nitro
        boostTint.alpha = 0.002
        boostTint.zPosition = 44
        addChild(boostTint)
        nitroShock = SKSpriteNode(texture: CarArt.nitroRingTexture)
        nitroShock.size = CGSize(width: 90, height: 90)
        nitroShock.blendMode = .add
        nitroShock.alpha = 0.002
        nitroShock.position = CGPoint(x: size.width / 2, y: size.height * 0.35)
        nitroShock.zPosition = 46
        addChild(nitroShock)
        nitroBanner = makeLabel(Strings.nitroGo, size: 34, color: UIColor(red: 0.45, green: 0.9, blue: 1.0, alpha: 1))
        nitroBanner.position = CGPoint(x: size.width / 2, y: size.height * 0.62)
        nitroBanner.zPosition = 20
        nitroBanner.alpha = 0.002
        hud.addChild(nitroBanner)
        // Haptic engines start lazily; get them ready so the first bump or nitro does not wait
        bumpHaptic.prepare()
        tickHaptic.prepare()
        notifyHaptic.prepare()

        // The gear is on the speedometer; the disc that repeated it over the pedals is gone
        gearLabel = makeLabel("D", size: 18, color: UIColor(red: 0.45, green: 0.95, blue: 0.6, alpha: 1))
    }

    // MARK: Level loading

    func load(level index: Int) {
        let loadStarted = CACurrentMediaTime()
        defer { levelLoadMilliseconds = (CACurrentMediaTime() - loadStarted) * 1000 }
        levelIndex = Levels.clamp(index)
        level = Levels.level(levelIndex)
        challenge = ParkChallenge.make(index: levelIndex, level: level, slot: slot)
        controlsLayer.removeAllActions()
        controlsLayer.alpha = 1
        hud.removeAllActions()
        hud.alpha = 1
        if challenge.wetGround { level.weather = challenge.snow ? .snow : .rain }
        failReason = nil
        lastHitWarned = false
        model?.results = nil
        worldFrozen = false
        guard builtSize != .zero, let world = world else { return }
        overlay.removeAllChildren()
        finalButton = nil
        obstacleBoxes = level.obstacles.map { $0.box }
        coneIndices = Set(level.obstacles.indices.filter { level.obstacles[$0].kind == .cone })
        knockedCones.removeAll()
        lastHitPosition = CGPoint(x: -9999, y: -9999)
        let spotSlots = level.freeSpots.isEmpty || level.race ? (friendPresent ? [slot, otherSlot] : [slot]) : []
        spotTarget = -1
        spotsGoneFailed = false
        var lapClock = CACurrentMediaTime()
        func lap(_ what: String) {
            guard PerfSettings.benchmark else { return }
            let now = CACurrentMediaTime()
            stage(String(format: "lap %@ %.0f ms", what, (now - lapClock) * 1000))
            lapClock = now
        }
        world.levelVenue = Venue.of(level: levelIndex)
        world.load(level: level, spotSlots: spotSlots, mySlot: slot)
        if !level.freeSpots.isEmpty && !level.race {
            world.buildFreeSpots(level.freeSpots.map { $0.def })
        }
        lap("world.load")
        setupPatrols(world)
        setupBonuses()
        lap("patrols+bonuses")
        // Only under the loading screen (later rounds load in view)
        if level.city != nil && !ready { world.beginWarmupSweep() }
        if level.race {
            // Draws once with the plate's fonts so the finish moment does not lay out glyphs cold
            // Letters and chips of the finish title are drawn now, so the finish starts without a hitch
            for title in [Strings.youWon.localUpper, Strings.finishBig, Strings.parkedBig] where finishGlyphs[title] == nil {
                finishGlyphs[title] = CarArt.titleGlyphs(title, size: 88)
            }
            _ = CarArt.finishStats([.init(icon: "stopwatch.fill", label: Strings.statTime, value: "0.0", unit: "s")], accent: .white)
            _ = CarArt.finishScrim
            // The title's shine uses a crop node: draw one once so its mask pass is ready
            let warmCrop = SKCropNode()
            let warmMask = SKSpriteNode(texture: CarArt.sheenTexture)
            warmMask.size = CGSize(width: 8, height: 8)
            warmCrop.maskNode = warmMask
            let warmShine = SKSpriteNode(texture: CarArt.sheenTexture)
            warmShine.size = CGSize(width: 8, height: 8)
            warmShine.blendMode = .add
            warmCrop.addChild(warmShine)
            warmCrop.alpha = 0.01
            warmCrop.position = CGPoint(x: size.width / 2, y: size.height / 2)
            hud.addChild(warmCrop)
            warmCrop.run(.sequence([.wait(forDuration: 0.5), .removeFromParent()]))
        }
        defer {
            stage(String(format: "level loaded in %.0f ms", (CACurrentMediaTime() - loadStarted) * 1000))
            world.warmUp { [weak self] in
                self?.stage("warm-up done")
                self?.becomeReady()
            }
            // Never wait on the GPU warm-up forever
            if !ready {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                    self?.stage("warm-up timeout")
                    self?.becomeReady()
                }
            }
        }

        botCars.forEach { $0.node.removeFromParentNode() }
        botCars.removeAll()
        traffic = nil
        if let city = level.city {
            let newTraffic = Traffic(map: city, starts: level.bots, seed: UInt64(levelIndex * 31 + 7),
                                     spots: level.race ? [] : level.freeSpots, hunters: level.race ? [] : level.hunters,
                                     racers: level.racers,
                                     finish: level.finishStreet.map { (a: $0.a, b: $0.b, point: level.spots[0].center) })
            newTraffic.authority = !online || isHost
            LeakWatch.track(newTraffic, "Traffic")
            traffic = newTraffic
            hunterHazard = Array(repeating: false, count: newTraffic.bots.count)
            setupSpotsChip()
            setupTaxi(world)
            setupRacers(newTraffic)
            for (index, bot) in newTraffic.bots.enumerated() {
                let rivalTaxi = level.taxi != nil && bot.hunt >= 0
                let racerColor: UIColor? = bot.racer ? ParkingScene.racerColors[bot.tint % ParkingScene.racerColors.count] : nil
                botCars.append(world.makeCar(color: racerColor ?? (rivalTaxi ? UIColor(red: 1, green: 0.78, blue: 0.08, alpha: 1)
                                                              : CarArt.parkedColors[bot.tint % CarArt.parkedColors.count]),
                                             style: CarStyle(rawValue: index % 3) ?? .sedan, variety: index &* 7 &+ bot.tint))
            }
            // At night the traffic drives with its lights on (faint, so it reads without glare)
            let night = level.weather == .night
            botCars.forEach { $0.setNightLights(night) }
        }
        lap("traffic cars")
        // People on the sidewalks (each player simulates their own: they are scenery that reacts)
        pedestrians = nil
        pedestrianNodes.removeAll()
        pedestrianStates.removeAll()
        pedestrianSince.removeAll()
        if let city = level.city {
            let people = PedestrianSystem(map: city, count: city.blocks.count >= 20 ? 36 : 22, seed: UInt64(levelIndex * 131 + 5))
            LeakWatch.track(people, "PedestrianSystem")
            pedestrians = people
            for _ in people.people {
                pedestrianNodes.append(world.addPedestrianNode())
            }
            updatePedestrianNodes()
        }
        // Benchmark: a line-up of both people in every clip in front of the car (to check them)
        if PerfSettings.benchmark && ProcessInfo.processInfo.arguments.contains("-pedtest") && level.city != nil {
            let start = level.starts[slot]
            let ahead = CGVector(dx: cos(start.heading), dy: sin(start.heading))
            let side = CGVector(dx: -ahead.dy, dy: ahead.dx)
            for (k, clip) in PedestrianModels.Clip.allCases.enumerated() {
                for character in 0..<2 {
                    let node = world.addPedestrianNode()
                    node.geometry = PedestrianModels.geometry(character: character, clip: clip, time: 0.45)
                    let along = 75 + CGFloat(character) * 22
                    let across = (CGFloat(k) - 3) * 15
                    let p = CGPoint(x: start.position.x + ahead.dx * along + side.dx * across,
                                    y: start.position.y + ahead.dy * along + side.dy * across)
                    node.position = World3D.vec(p)
                    node.eulerAngles.y = Float(start.heading + .pi)
                }
            }
        }
        lap("pedestrians")
        // Arcade extras of the level
        streetProps = level.city != nil ? world.addProps(level.props) : nil
        lap("props")
        police = nil
        remotePolice = nil
        remotePoliceTarget = nil
        policeCooldownUntil = 0
        busted = false
        bustedNode?.removeFromParent()
        bustedNode = nil
        if policeBanner.parent != nil {
            policeBanner.alpha = 0.002
            policeEdges.forEach { $0.alpha = 0.002 }
        }
        policeWarningShown = false
        placeStatus()
        trail.removeAll()
        nearMissAt.removeAll()
        setupGhost()
        lap("ghost")
        runDriftPoints = 0
        runNearMisses = 0
        runEscapes = 0
        runTopSpeed = 0
        drifting = false
        driftScore = 0
        lastDriftScore = 0
        airTime = 0
        shownDriftPoints = -1
        driftLabel.alpha = 0.002
        // Beams at night only (rain and snow levels are daytime)
        localCar?.setHeadlights(level.city != nil && level.weather == .night)
        remoteCar?.setNightLights(level.city != nil && level.weather == .night)
        audio.setLoop("rain", volume: isRaining ? 0.3 : 0)
        audio.setLoop("snow", volume: isSnowing ? 0.32 : 0)
        // Spray particles exist from the start (no first-use hitch), idle until the car moves
        localCar?.setSpray(isRaining || isSnowing ? 0.001 : 0)
        // The horn matters in traffic only: parking levels keep fewer buttons
        hornButton.isHidden = !isCity
        setupRainLayers()
        lap("headlights+rain")
        audio.setLoop("siren", volume: 0)
        squealLevel = 0
        audio.setLoop("skid", volume: 0)
        route = []
        routeClock = 0
        giveUp = 20
        // A new series (the first round of a city or race match; a car race used to carry the
        // score over from the last match)
        if Levels.roundIndex(levelIndex) == 0 || !Levels.isCity(levelIndex) {
            myWins = 0
            friendWins = 0
            onlineMatch = online
        } else if online {
            onlineMatch = true
        }

        let start = level.starts[slot]
        carPosition = start.position
        heading = start.heading
        travelHeading = start.heading
        velocity = 0
        steer = 0
        wheelInput = 0
        gear = .drive
        engaged = false
        braking = false
        longitudinalAccel = 0
        lateralAccel = 0
        suspension = Suspension()
        frontKerb = 0
        rearKerb = 0
        let remoteStart = level.starts[otherSlot]
        remotePosition = remoteStart.position
        remoteHeading = remoteStart.heading
        remoteSteer = 0
        remoteBraking = false
        remoteReversing = false
        remoteTarget = nil
        remoteSnapshots.removeAll()
        remotePoseLast = nil

        phase = .countdown
        countdown = 3
        elapsed = 0
        hits = 0
        lastHitAt = -10
        parkHold = 0
        localParked = false
        localTime = 0
        remoteParked = false
        remoteTime = 0
        remoteHits = 0
        resultsShown = false
        roundCounted = false
        advanceScheduled = false
        newBest = false
        lastPrecision = nil
        precisionBest = false
        nitro = 0.5
        boostTime = 0
        remoteBoost = false
        statusLabel.text = ""
        countdownLabel.text = ""
        setCountdown("3")
        countdownNode.removeAllActions()
        countdownNode.alpha = 0
        countdownNode.setScale(1)
        countdownNode.position = countdownHome
        countdownBar.xScale = 0.001
        topBar.removeAllActions()
        topBar.alpha = 1
        statusLabel.removeAllActions()
        statusLabel.alpha = 1
        holdShown = false
        holdModule.removeAllActions()
        holdModule.alpha = 0
        hitsLabel.text = "0"
        gearLabel.text = "1"
        gearIndex = 1
        rpm = idleRPM
        shiftCut = 0
        audio.setLoop("wind", volume: 0)
        refreshLevelLabel()
        codeLabel.text = online ? "\(Strings.roomCode): \(model?.roomCode ?? "")" : ""
        remoteCheck.isHidden = true
        holdRing.path = nil
        world.follow(position: carPosition, heading: heading, dt: 0, snap: true)
        lap("reset+follow")
        buildMinimap()
        lap("minimap")
        updateCarNodes()
        countdownNode.isHidden = !ready
        if ready {
            popCountdown(go: false)
            tickHaptic.impactOccurred()
            audio.play("beep", volume: 0.6)
        }
    }

    /// The world is built and its shaders are compiled: hide the loading screen, start the countdown.
    private func stage(_ text: String) {
        if PerfSettings.benchmark {
            FileHandle.standardError.write(("PPSTAGE " + text + "\n").data(using: .utf8)!)
        }
    }

    /// Each number slams in (big and blurred-fast, then a springy settle) while the last one
    /// shrinks away; the band wipes across, a shock ring spreads and the lamp that just lit flares.
    /// GO lights every lamp green, flashes, throws speed streaks and lifts away.
    private func popCountdown(go: Bool) {
        if benchmark {
            // Test runs: save the countdown layer as an image at a few moments of each stage
            let name = go ? "go" : "\(countdownStep)"
            for delay in [0.08, 0.3, 0.7] {
                run(.wait(forDuration: delay)) { [weak self] in self?.saveCountdownImage("countdown-\(name)-\(Int(delay * 100))") }
            }
        }
        countdownNode.isHidden = false
        if countdownNode.alpha < 0.99 || countdownNode.action(forKey: "leave") != nil {
            countdownNode.removeAllActions()
            countdownNode.position = countdownHome
            countdownNode.setScale(1)
            countdownNode.alpha = 1
            // The radar line (just under the top bar) waits until the count is over
            statusLabel.removeAllActions()
            statusLabel.alpha = 0
        }
        // Each number slams in from big
        countdownNode.removeAction(forKey: "slam")
        countdownNode.setScale(1.5)
        countdownNode.alpha = 0
        let slam = SKAction.group([.scale(to: 1, duration: 0.2), .fadeIn(withDuration: 0.12)])
        slam.timingMode = .easeOut
        countdownNode.run(slam, withKey: "slam")
        if benchmark {
            // Test runs: the whole screen and the 3D view alone, during the count and after GO
            let tag = "\(levelIndex)-\(go ? "go" : "\(countdownStep)")"
            run(.wait(forDuration: 0.3)) { [weak self] in
                saveWindowSnapshot(named: "shot-\(tag)")
                if let image = self?.world?.renderer?.snapshot(), let data = image.pngData(),
                   let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? data.write(to: folder.appendingPathComponent("scene-\(tag).png"))
                }
            }
        }
        if go {
            countdownBar.xScale = 1
            // Grows a little and fades: the road ahead is free at once
            let leave = SKAction.group([.fadeOut(withDuration: 0.25), .scale(to: 1.25, duration: 0.25)])
            leave.timingMode = .easeIn
            countdownNode.run(.sequence([.wait(forDuration: 0.45), leave, .hide()]), withKey: "leave")
            statusLabel.run(.sequence([.wait(forDuration: 0.7), .fadeIn(withDuration: 0.2)]))
        }
    }

    private func saveCountdownImage(_ name: String) {
        guard let view = view, let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let backdrop = SKSpriteNode(color: UIColor(red: 0.2, green: 0.3, blue: 0.25, alpha: 1), size: size)
        backdrop.position = CGPoint(x: size.width / 2, y: size.height / 2)
        let holder = SKNode()
        holder.addChild(backdrop)
        let copy = countdownNode.copy() as! SKNode
        holder.addChild(copy)
        guard let texture = view.texture(from: holder) else { return }
        let image = UIImage(cgImage: texture.cgImage())
        try? image.pngData()?.write(to: folder.appendingPathComponent(name + ".png"))
    }

    /// The bar fills smoothly over the whole countdown.
    private func updateCountdownRing() {
        countdownBar.xScale = max(0.001, min(1, (3 - countdown) / 3))
    }

    private func becomeReady() {
        guard !ready, !readyRequested else { return }
        readyRequested = true
        stage("ready")
        revealWhenWarm()
    }

    /// The warm-up camera tour must finish (every material, mesh and lamp color of the level drawn
    /// once) before the loading screen goes; cutting it short left first-sight stalls in the race.
    /// It then ends under the curtain, so the first thing the player sees is the chase camera.
    private func revealWhenWarm(waited: TimeInterval = 0) {
        if let world = world, !world.sweepComplete, waited < 5 {
            run(.wait(forDuration: 0.1)) { [weak self] in self?.revealWhenWarm(waited: waited + 0.1) }
            return
        }
        world?.endWarmupSweep()
        if let model = model {
            model.sceneReady { [weak self] in self?.startCountdown() }
        } else {
            startCountdown()
        }
    }

    /// Runs once the loading screen has gone.
    private func startCountdown() {
        guard !ready else { return }
        ready = true
        world?.endWarmupSweep()
        countdownNode.isHidden = false
        countdown = 3
        setCountdown("3")
        popCountdown(go: false)
        tickHaptic.impactOccurred()
        audio.play("beep", volume: 0.6)
    }

    // MARK: Network

    func handleNetwork(_ message: [String: Any]) {
        guard let type = message["t"] as? String else { return }
        let messageLevel = message["l"] as? Int ?? -1
        switch type {
        case "s":
            guard messageLevel == levelIndex,
                  let x = message["x"] as? Double, let y = message["y"] as? Double, let h = message["h"] as? Double else { return }
            let target = CGPoint(x: x, y: y)
            if remoteTarget == nil {
                remotePosition = target
                remoteHeading = CGFloat(h)
            }
            remoteTarget = (target, CGFloat(h))
            let now = CACurrentMediaTime()
            let sentAt = message["ts"] as? Double ?? now
            let offset = now - sentAt
            // The fastest packet sets the offset; it follows a faster one quickly but smoothly (a
            // jump moved the played-back time, and the car with it), slower ones barely
            if let current = clockOffset, abs(offset - current) < 0.3 {
                clockOffset = current + (offset - current) * (offset >= current ? 0.02 : 0.25)
            } else {
                clockOffset = offset
            }
            if let last = remoteSnapshots.last, sentAt <= last.time { return }
            var snapshot = RemoteSnapshot(time: sentAt, position: target, heading: CGFloat(h),
                                          velocity: CGFloat(message["v"] as? Double ?? 0))
            if let w = message["w"] as? Double { snapshot.yawRate = CGFloat(w) }
            if let a = message["a"] as? Double { snapshot.accel = CGFloat(a) }
            remoteSnapshots.append(snapshot)
            if remoteSnapshots.count > 30 { remoteSnapshots.removeFirst(remoteSnapshots.count - 30) }
            remoteSteer = CGFloat(message["st"] as? Double ?? 0)
            remoteBoost = (message["n"] as? Int ?? 0) == 1
            remoteBraking = (message["b"] as? Int ?? 0) == 1
            remoteReversing = (message["r"] as? Int ?? 0) == 1
            if let pose = message["pp"] as? [Double], pose.count == 3 {
                remotePoliceTarget = (CGPoint(x: pose[0], y: pose[1]), CGFloat(pose[2]))
            } else {
                remotePoliceTarget = nil
            }
        case "take":
            guard messageLevel == levelIndex, !isHost, let spot = message["s"] as? Int, let bot = message["b"] as? Int else { return }
            traffic?.applyTake(spot: spot, bot: bot)
            if level.taxi != nil {
                rivalGotCustomer(bot: bot)
            } else {
                spotGone(spot, byHunter: true)
            }
        case "pick":
            guard messageLevel == levelIndex, level.taxi != nil else { return }
            let theirs = message["at"] as? Double ?? 0
            // The earlier pick-up wins (the same moment: the lower slot)
            if pickedAt < 0 || theirs < pickedAt || (theirs == pickedAt && otherSlot < slot) {
                traffic?.claim(0)
                if taxiState == .riding || taxiState == .boarding {
                    taxiState = .waiting
                    customerNode?.isHidden = false
                    customerSign?.isHidden = false
                }
                rivalGotCustomer(bot: nil)
            }
        case "p":
            guard messageLevel == levelIndex else { return }
            if spotWars, let x = message["x"] as? Double, let y = message["y"] as? Double,
               let spot = level.freeSpots.indices.first(where: { level.freeSpots[$0].def.box.contains(CGPoint(x: x, y: y)) }) {
                spotGone(spot, byHunter: false)
            }
            remoteParked = true
            remotePoliceTarget = nil
            remoteTime = message["time"] as? Double ?? -1
            remoteHits = message["hits"] as? Int ?? 0
            if let x = message["x"] as? Double, let y = message["y"] as? Double, let h = message["h"] as? Double {
                remoteTarget = (CGPoint(x: x, y: y), CGFloat(h))
                remoteSnapshots.removeAll()
            }
            remoteSteer = 0
            remoteBraking = false
            remoteReversing = false
            remoteCheck.isHidden = false
            notifyHaptic.notificationOccurred(.warning)
            checkLevelDone()
        case "hn":
            remoteHonk()
        case "hit":
            guard messageLevel == levelIndex else { return }
            friendHitUs(message)
        case "pi":
            // Echoed straight back so the friend can time the round trip
            model?.sendFast(["t": "po", "ts": message["ts"] as? Double ?? 0])
        case "po":
            guard let sent = message["ts"] as? Double, sent > 0 else { return }
            let half = max(0, min(0.4, (CACurrentMediaTime() - sent) / 2))
            oneWayDelay += (half - oneWayDelay) * 0.3
            // The delay beside the room code, for testing on real phones
            if online, let code = model?.roomCode {
                let path = model?.net.fastActive == true ? " · UDP" : ""
                codeLabel.text = "\(Strings.roomCode): \(code) · \(Int((oneWayDelay * 1000).rounded())) ms\(path)"
            }
        case "b":
            guard messageLevel == levelIndex, !isHost, let data = message["d"] as? [Int] else { return }
            traffic?.apply(data)
        default:
            break
        }
    }

    private func setCountdown(_ text: String) {
        let go = Int(text) == nil
        countdownStep = Int(text) ?? 0
        countdownColor = go ? UIColor(red: 0.3, green: 1.0, blue: 0.55, alpha: 1) : .white
        countdownLabel.text = text
        countdownShadow.text = text
        countdownLabel.fontColor = countdownColor
        countdownLabel.fontSize = go ? 92 : 118
        countdownShadow.fontSize = countdownLabel.fontSize
    }

    /// Plays the other car back `interpolationDelay` behind the newest state, blending between
    /// the two states around that moment; extrapolates briefly if packets are late.
    private func updateRemoteCar(_ dt: CGFloat) {
        guard let target = remoteTarget else { return }
        guard let offset = clockOffset, let newest = remoteSnapshots.last else {
            // No timed states (parked or old version): ease to the last known pose
            let k = min(1, dt * 10)
            remotePosition = CGPoint(x: remotePosition.x + (target.0.x - remotePosition.x) * k,
                                     y: remotePosition.y + (target.0.y - remotePosition.y) * k)
            remoteHeading += CGFloat.angleDelta(remoteHeading, target.1) * k
            return
        }
        let renderTime = CACurrentMediaTime() - offset - interpolationDelay
        var pose: (CGPoint, CGFloat)
        if renderTime >= newest.time {
            let ahead = CGFloat(min(renderTime - newest.time, 0.35))
            pose = (CGPoint(x: newest.position.x + cos(newest.heading) * newest.velocity * ahead,
                            y: newest.position.y + sin(newest.heading) * newest.velocity * ahead), newest.heading)
        } else if let first = remoteSnapshots.first, renderTime <= first.time {
            pose = (first.position, first.heading)
        } else {
            var index = remoteSnapshots.count - 1
            while index > 0 && remoteSnapshots[index - 1].time > renderTime { index -= 1 }
            let a = remoteSnapshots[max(0, index - 1)]
            let b = remoteSnapshots[index]
            let span = max(b.time - a.time, 0.001)
            let f = CGFloat(max(0, min(1, (renderTime - a.time) / span)))
            pose = (CGPoint(x: a.position.x + (b.position.x - a.position.x) * f,
                            y: a.position.y + (b.position.y - a.position.y) * f),
                    a.heading + CGFloat.angleDelta(a.heading, b.heading) * f)
            // Drop states that are no longer needed
            if index > 2 { remoteSnapshots.removeFirst(index - 2) }
        }
        // Drawn where the friend is now, not where they were: the states are played back
        // `interpolationDelay` late and took `oneWayDelay` to arrive, so the pose is carried that
        // far ahead along the friend's speed and turn (otherwise a car seen beside us was really
        // metres further on, and a hit on it never happened in the friend's game)
        if let last = remoteSnapshots.last, abs(last.velocity) > 1, !remoteParked {
            let lead = CGFloat(min(0.3, interpolationDelay + oneWayDelay))
            // How fast it turns and speeds up or brakes, from its last two states, so a car in a
            // bend is carried round the bend and a braking car is not carried past its stop
            // (sent by the friend's game, which knows them exactly; estimated from two states only
            // for an older version, which jittered with every packet). Smoothed here as well, so
            // the carried-ahead pose glides instead of twitching as each state lands.
            var yawTarget: CGFloat = 0
            var accelTarget: CGFloat = 0
            if let w = last.yawRate, let a = last.accel {
                yawTarget = w
                accelTarget = a
            } else if remoteSnapshots.count >= 2 {
                let before = remoteSnapshots[remoteSnapshots.count - 2]
                let span = CGFloat(max(last.time - before.time, 0.02))
                yawTarget = CGFloat.angleDelta(before.heading, last.heading) / span
                accelTarget = (last.velocity - before.velocity) / span
            }
            let k = min(1, dt * 12)
            remoteYawRate += (max(-2.5, min(2.5, yawTarget)) - remoteYawRate) * k
            remoteAccel += (max(-900, min(600, accelTarget)) - remoteAccel) * k
            let yawRate = remoteYawRate
            let accel = remoteAccel
            // Distance along the path: never past a stop (a braking car does not reverse)
            var travel = last.velocity * lead + accel * lead * lead / 2
            if last.velocity > 0 { travel = max(0, travel) } else { travel = min(0, travel) }
            let midHeading = pose.1 + yawRate * lead / 2
            pose = (CGPoint(x: pose.0.x + cos(midHeading) * travel, y: pose.0.y + sin(midHeading) * travel),
                    pose.1 + yawRate * lead)
        }
        // Corrections glide in instead of jumping: what was drawn last frame keeps its offset from
        // the computed pose and that offset fades over about a tenth of a second. Smooth motion
        // has no offset, so the car is not drawn behind where it is (a plain low-pass did that).
        // Only a real jump (a new round, a respawn) snaps; it used to snap past 12 m, which a late
        // burst of states on a mobile connection easily reached: the "teleport".
        if let last = remotePoseLast, remotePosition.distance(to: pose.0) < 400 {
            let fade = CGFloat(exp(-Double(dt) / 0.12))
            remotePosition = CGPoint(x: pose.0.x + (remotePosition.x - last.0.x) * fade,
                                     y: pose.0.y + (remotePosition.y - last.0.y) * fade)
            remoteHeading = pose.1 + CGFloat.angleDelta(last.1, remoteHeading) * fade
        } else {
            remotePosition = pose.0
            remoteHeading = pose.1
        }
        remotePoseLast = pose
    }

    private func refreshLevelLabel() {
        if isCity && online && friendPresent {
            levelLabel.text = Levels.title(levelIndex, online: true) + " · " + Strings.score(myWins, friendWins)
        } else {
            levelLabel.text = Levels.title(levelIndex, online: onlineMatch) + " · " + level.name
        }
    }

    func retryLevel() {
        loadBehindCurtain(level: levelIndex)
    }

    func nextLevel() {
        loadBehindCurtain(level: Levels.clamp(levelIndex + 1))
    }

    /// Later rounds load behind the loading screen too (building a level in view froze the game
    /// for a moment and cut straight to the new map): the curtain fades in, the level is built and
    /// warmed up under it, then it fades out and the countdown starts.
    func loadBehindCurtain(level index: Int) {
        guard let model = model else {
            load(level: index)
            return
        }
        model.showCurtain(level: index) { [weak self] in
            guard let self = self else { return }
            self.ready = false
            self.readyRequested = false
            self.load(level: index)
        }
    }

    // MARK: Benchmark

    /// Drives along the route at full throttle, uses nitro, backs out when stuck, and measures
    /// 20 seconds of frames once driving has settled.
    private func runAutopilot(_ dt: CGFloat) {
        if let role = ParkingScene.netRole {
            netTestDrive(role, dt)
            return
        }
        autoControls = []
        guard phase != .countdown, !benchDone else { return }
        benchClock += finishAnimating ? CGFloat(1.0 / 60.0) : dt
        if !benchRecording && benchClock > 2 {
            benchRecording = true
            FrameMonitor.shared.start()
        }
        if benchClock > 1.0 && benchClock - dt <= 1.0 { world?.saveSnapshot(named: "shot-start") }
        // (not behind the results card: a snapshot of the paused 3D view stalls)
        if benchClock > 12 && benchClock - dt <= 12 && !worldFrozen {
            FrameMonitor.shared.mark("snapshot")
            world?.saveSnapshot(named: "shot-mid")
            saveFullSnapshot()
        }
        if benchRecording && benchClock > 22 {
            finishBenchmark()
            return
        }
        // Taxi test: the car stops by the customer (pick-up), pictures saved by the app
        if benchmark && ProcessInfo.processInfo.arguments.contains("-taxitest"), let taxi = level.taxi, phase == .driving {
            if !taxiTestPlaced && elapsed > 1.5 {
                taxiTestPlaced = true
                carPosition = CGPoint(x: taxi.customer.x + cos(taxi.facing) * 62, y: taxi.customer.y + sin(taxi.facing) * 62)
                heading = taxi.facing - CGFloat.pi / 2
                velocity = 0
                for (at, name) in [(0.7, "shot-taxi-1"), (3.6, "shot-taxi-2")] {
                    run(.wait(forDuration: at)) { Task { @MainActor in saveWindowSnapshot(named: name) } }
                }
            }
            if taxiTestPlaced {
                velocity = 0
                return
            }
        }
        // Finish test: put the car just before the finish line at speed so it crosses it
        if PerfSettings.finishTest && level.race && !finishTestPlaced && benchClock > 6 {
            finishTestPlaced = true
            let finish = level.spots[slot]
            let dir = CGPoint(x: cos(finish.angle), y: sin(finish.angle))
            let normal = CGPoint(x: dir.y, y: -dir.x)
            carPosition = CGPoint(x: finish.center.x - dir.x * 140 + normal.x * CityMap.laneOffset,
                                  y: finish.center.y - dir.y * 140 + normal.y * CityMap.laneOffset)
            heading = finish.angle
            velocity = 120
            gear = .drive
            finishTestAt = Double(benchClock - 2)
        }
        if PerfSettings.finishTest && finishTestPlaced && level.race && phase == .driving && !localParked {
            checkParking(dt)
            autoControls = [.forward]
            return
        }
        guard phase == .driving else { return }
        if autoReverse > 0 {
            autoReverse -= dt
            autoControls = [.reverse, .left]
            return
        }
        autoControls.insert(.forward)
        var relative: CGFloat = 0
        if route.count >= 2 {
            let k = route.count > 2 && carPosition.distance(to: route[1]) < 95 ? 2 : 1
            relative = CGFloat.angleDelta(heading, atan2(route[k].y - carPosition.y, route[k].x - carPosition.x))
            if relative > 0.08 { autoControls.insert(.left) } else if relative < -0.08 { autoControls.insert(.right) }
        }
        stuckTime = abs(velocity) < 6 ? stuckTime + dt : 0
        if stuckTime > 1.2 {
            stuckTime = 0
            autoReverse = 1.0
        }
        if nitro >= 1 && abs(relative) < 0.25 { fireNitro() }
    }

    /// Benchmark helper: 3D view plus the HUD drawn on top, saved as Documents/shot-hud.png.
    private func saveFullSnapshot() {
        guard let world = world, let base = world.renderer?.snapshot(), let skView = view,
              let texture = skView.texture(from: self),
              let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let hudImage = UIImage(cgImage: texture.cgImage())
        let canvas = CGSize(width: size.width, height: size.height)
        let image = UIGraphicsImageRenderer(size: canvas).image { _ in
            base.draw(in: CGRect(origin: .zero, size: canvas))
            hudImage.draw(in: CGRect(origin: .zero, size: canvas))
        }
        try? image.pngData()?.write(to: folder.appendingPathComponent("shot-hud.png"))
    }

    private func finishBenchmark() {
        benchDone = true
        FrameMonitor.shared.stop()
        let summary = FrameMonitor.shared.summary()
        let stats = world.map { SceneStats.count($0.scene.rootNode) } ?? (0, 0, 0, 0)
        let effective = world.map { SceneStats.effective($0.scene.rootNode, camera: $0.cameraNode.simdWorldPosition) } ?? (0, 0)
        let report: [String: Any] = [
            "mode": PerfSettings.optimized ? "optimized" : "legacy",
            "device": UIDevice.current.model, "screenScale": Double(UIScreen.main.scale),
            "level": Levels.title(levelIndex), "bots": traffic?.bots.count ?? 0,
            "parkedCars": level.obstacles.filter { $0.kind == .car }.count,
            "frames": summary.frames, "seconds": (summary.seconds * 100).rounded() / 100,
            "avgFPS": (summary.averageFPS * 10).rounded() / 10,
            "onePercentLowFPS": (summary.onePercentLowFPS * 10).rounded() / 10,
            "frameMsP50": (summary.p50 * 100).rounded() / 100, "frameMsP95": (summary.p95 * 100).rounded() / 100,
            "frameMsP99": (summary.p99 * 100).rounded() / 100, "frameMsWorst": (summary.worst * 100).rounded() / 100,
            "jankFramesOver25ms": summary.jankFrames,
            "updateMsAvg": (summary.updateAverage * 1000).rounded() / 1000,
            "updateMsP95": (summary.updateP95 * 1000).rounded() / 1000,
            "renderCpuMsAvg": (summary.renderCpuAverage * 1000).rounded() / 1000,
            "renderCpuMsP95": (summary.renderCpuP95 * 1000).rounded() / 1000,
            "drawCallsAtCamera": effective.0, "trianglesAtCamera": effective.1,
            "nodeBreakdown": world.map { SceneStats.breakdown($0.scene.rootNode) } ?? [:],
            "sceneNodes": stats.0, "geometryNodes": stats.1, "drawCallsFullDetail": stats.2, "triangles": stats.3,
            "levelLoadMs": (levelLoadMilliseconds * 10).rounded() / 10,
            "hits": hits,
            "spikes": FrameMonitor.shared.spikes(over: 50),
            "spikeDetails": FrameMonitor.shared.spikeDetails(over: 45),
            "slowUpdates": FrameMonitor.shared.slowUpdates(over: 12),
            "nitroAt": nitroFiredAt,
            "finishTestAt": finishTestAt, "finishCrossAt": finishCrossAt
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("PPBENCH " + text)
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: folder.appendingPathComponent("bench.json"))
            }
        }
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }

    // MARK: Nitro

    private func fireNitro() {
        guard phase == .driving, !localParked, !isBoosting else { return }
        guard nitro >= 1 else {
            nitroButton.removeAction(forKey: "deny")
            nitroButton.run(.sequence([.moveBy(x: -5, y: 0, duration: 0.04), .moveBy(x: 10, y: 0, duration: 0.06),
                                       .moveBy(x: -5, y: 0, duration: 0.04)]), withKey: "deny")
            tickHaptic.impactOccurred(intensity: 0.3)
            return
        }
        nitro = 0
        boostTime = boostDuration
        if benchmark { FrameMonitor.shared.mark("nitro") }
        if benchRecording { nitroFiredAt.append((Double(benchClock - 2) * 10).rounded() / 10) }
        engaged = true
        if gear == .reverse && velocity <= 2 { gear = .drive }
        velocity = max(velocity, 0) + 45
        var t0 = CACurrentMediaTime()
        func lap(_ name: String) {
            guard benchmark else { return }
            let now = CACurrentMediaTime()
            let ms = (now - t0) * 1000
            if ms > 5 { stage(String(format: "nitro %@ %.0f ms", name, ms)) }
            t0 = now
        }
        audio.play("nitro", volume: 0.8)
        lap("audio")
        bumpHaptic.impactOccurred(intensity: 1.0)
        lap("haptic")
        world?.shake(strength: 3)
        boostVisual = 1.3   // lens punch, eases back to 1
        // Shockwave ring from behind the car and the banner: both made when the level is built
        // (an SKShapeNode glow compiled its shader on the first nitro and stalled a frame)
        nitroShock.removeAllActions()
        nitroShock.setScale(0.6)
        nitroShock.alpha = 1
        let expand = SKAction.group([.scale(to: 6, duration: 0.45), .fadeAlpha(to: 0.002, duration: 0.45)])
        expand.timingMode = .easeOut
        nitroShock.run(expand)
        nitroBanner.removeAllActions()
        nitroBanner.position = CGPoint(x: size.width / 2, y: size.height * 0.62)
        nitroBanner.setScale(0.5)
        nitroBanner.alpha = 1
        nitroBanner.run(.sequence([.scale(to: 1.15, duration: 0.12), .scale(to: 1.0, duration: 0.1), .wait(forDuration: 0.5),
                                   .group([.fadeAlpha(to: 0.002, duration: 0.3), .moveBy(x: 0, y: 20, duration: 0.3)])]))
        lap("effects")
    }

    private func updateNitro(_ dt: CGFloat) {
        if isBoosting {
            boostTime = max(0, boostTime - dt)
            if phase != .driving || localParked { boostTime = 0 }
        } else if phase == .driving && !localParked {
            let before = nitro
            nitro = min(1, nitro + dt / nitroFillTime)
            if before < 1 && nitro >= 1 {
                tickHaptic.impactOccurred(intensity: 0.7)
                nitroButton.run(.sequence([.scale(to: 1.15, duration: 0.1), .scale(to: 1.0, duration: 0.15)]))
            }
        }
        boostVisual = approach(boostVisual, isBoosting ? 1 : 0, (isBoosting ? 5 : 2) * dt)
        world?.setBoost(boostVisual)
        localCar?.setNitro(isBoosting)
        remoteCar?.setNitro(remoteBoost && friendPresent)

        // Ring: fill level, or remaining boost while burning
        let fraction = isBoosting ? boostTime / boostDuration : nitro
        // Rebuilding a shape path re-tessellates it: only when the ring visibly changes
        let nitroStep = fraction > 0.01 ? Int((fraction * 120).rounded()) : -1
        if nitroStep != shownNitroStep {
            shownNitroStep = nitroStep
            if nitroStep >= 0 {
                let path = CGMutablePath()
                path.addArc(center: .zero, radius: 39, startAngle: CGFloat.pi / 2,
                            endAngle: CGFloat.pi / 2 - CGFloat(nitroStep) / 120 * 2 * CGFloat.pi, clockwise: true)
                nitroRing.path = path
            } else {
                nitroRing.path = nil
            }
        }
        let ready = nitro >= 1 && !isBoosting
        nitroRing.strokeColor = isBoosting ? UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1)
                                           : (ready ? UIColor(red: 0.35, green: 1.0, blue: 0.9, alpha: 1) : UIColor(red: 0.30, green: 0.70, blue: 1.0, alpha: 1))
        nitroButton.alpha = ready || isBoosting ? 1 : 0.75
        if ready && nitroIcon.action(forKey: "pulse") == nil {
            nitroIcon.run(.repeatForever(.sequence([.scale(to: 1.2, duration: 0.35), .scale(to: 1.0, duration: 0.35)])), withKey: "pulse")
        } else if !ready {
            nitroIcon.removeAction(forKey: "pulse")
            nitroIcon.setScale(1)
        }

        // Speed lines and blue tint
        boostTint.alpha = max(0.002, boostVisual * 0.75)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
        let maxRadius = hypot(size.width, size.height) * 0.6
        for index in speedLines.indices {
            var line = speedLines[index]
            if boostVisual < 0.02 {
                line.sprite.alpha = 0.002
                continue
            }
            line.radius += (700 + 900 * boostVisual) * dt
            if line.radius > maxRadius {
                line.radius = size.height * 0.3 + CGFloat.random(in: 0...60)
                line.angle = CGFloat.random(in: 0...(2 * CGFloat.pi))
            }
            line.sprite.position = CGPoint(x: center.x + cos(line.angle) * line.radius, y: center.y + sin(line.angle) * line.radius)
            line.sprite.zRotation = line.angle - CGFloat.pi / 2
            line.sprite.alpha = 0.5 * boostVisual * min(1, (line.radius - size.height * 0.25) / 120)
            line.sprite.yScale = 0.6 + boostVisual
            speedLines[index] = line
        }
    }

    // MARK: Horn

    private func honk() {
        guard lastUpdate - lastHorn > 0.25 else { return }
        lastHorn = lastUpdate
        pendingHorn = carPosition
        audio.play("horn", volume: 0.5)
        tickHaptic.impactOccurred(intensity: 0.9)
        hornButton.removeAction(forKey: "pulse")
        hornButton.setScale(1)
        hornButton.run(.sequence([.scale(to: 0.86, duration: 0.05), .scale(to: 1.0, duration: 0.18)]), withKey: "pulse")
        if online && friendPresent {
            model?.send(["t": "hn"])
        }
    }

    private func remoteHonk() {
        guard friendPresent else { return }
        pendingHorn = remotePosition
        let distance = hypot(remotePosition.x - carPosition.x, remotePosition.y - carPosition.y)
        audio.play("horn", volume: Float(max(0.45, min(0.8, 0.85 - distance / 2500))))
        bumpHaptic.impactOccurred(intensity: 0.6)

        var point = world?.project(remotePosition, height: 3.2) ?? CGPoint(x: -10000, y: 0)
        point.x = max(70, min(size.width - 70, point.x))
        point.y = max(90, min(size.height - 70, point.y))
        let bubble = makeGlass(width: 46, height: 46)
        bubble.position = point
        bubble.addChild(makeIcon("horn.blast.fill", size: 20, color: CarArt.playerColors[otherSlot].lighter(by: 0.25)))
        bubble.setScale(0.4)
        fxLayer.addChild(bubble)
        bubble.run(.sequence([
            .scale(to: 1.15, duration: 0.12),
            .scale(to: 1.0, duration: 0.1),
            .wait(forDuration: 0.5),
            .group([.fadeOut(withDuration: 0.35), .moveBy(x: 0, y: 18, duration: 0.35)]),
            .removeFromParent()
        ]))
        friendMarker.run(.sequence([.scale(to: 2.0, duration: 0.12), .scale(to: 1.0, duration: 0.25)]))
    }

    func friendJoined() {
        friendPresent = true
        online = true
    }

    func friendLeft() {
        friendPresent = false
        online = false
        remoteTarget = nil
        showToast(Strings.friendLeft)
        if resultsShown {
            // The card stays as it was (the round is not judged again, which counted it twice
            // and turned a win into a draw); one that was waiting to move on with the friend gets
            // buttons of its own
            if !advanceScheduled, let results = model?.results, case .autoNext = results.footer {
                let last = onlineMatch ? matchOver : Levels.isLast(levelIndex)
                model?.results = results.with(footer: last ? .final : .solo(hasNext: true))
            }
            return
        }
        if phase == .finished { checkLevelDone() }
    }

    private func sendState() {
        model?.sendFast(["t": "s", "l": levelIndex, "ts": CACurrentMediaTime(),
                     "x": Double(carPosition.x), "y": Double(carPosition.y),
                     "h": Double(heading), "v": Double(velocity), "st": Double(steer),
                     "w": Double(sentYawRate), "a": Double(longitudinalAccel),
                     "b": braking ? 1 : 0, "r": (gear == .reverse && velocity < -1) ? 1 : 0, "n": isBoosting ? 1 : 0,
                     "pp": police.map { [Double($0.position.x), Double($0.position.y), Double($0.heading)] } ?? []])
    }

    // MARK: Input

    private func hitControl(at point: CGPoint) -> Control? {
        if leftButton.frame.insetBy(dx: -8, dy: -14).contains(point) { return .left }
        if rightButton.frame.insetBy(dx: -8, dy: -14).contains(point) { return .right }
        if gasPedal.frame.insetBy(dx: -14, dy: -14).contains(point) { return .forward }
        if reversePedal.frame.insetBy(dx: -14, dy: -14).contains(point) { return .reverse }
        if driftButton.parent != nil && driftButton.frame.insetBy(dx: -10, dy: -10).contains(point) { return .handbrake }
        return nil
    }

    /// Automated test hook (-crashtest): holds a pedal as if a finger were on it.
    func testHold(_ pedal: String) {
        switch pedal {
        case "reverse": autoControls = [.reverse]
        case "forward": autoControls = [.forward]
        case "left": autoControls = [.forward, .left]
        default: autoControls = []
        }
        refreshPedals()
    }

    private func isPressed(_ control: Control) -> Bool {
        // Pulled over by the police: hands off until let go
        if busted { return false }
        return autoControls.contains(control) || activeTouches.values.contains(control)
    }

    private func refreshPedals() {
        let gasDown = isPressed(.forward)
        let reverseDown = isPressed(.reverse)
        gasPedal.setScale(gasDown ? 0.93 : 1)
        gasPedal.alpha = gasDown ? 1 : 0.88
        reversePedal.setScale(reverseDown ? 0.93 : 1)
        reversePedal.alpha = reverseDown ? 1 : 0.88
        let leftDown = isPressed(.left)
        let rightDown = isPressed(.right)
        leftButton.setScale(leftDown ? 0.92 : 1)
        leftButton.alpha = leftDown ? 1 : 0.88
        rightButton.setScale(rightDown ? 0.92 : 1)
        rightButton.alpha = rightDown ? 1 : 0.88
        let driftDown = isPressed(.handbrake)
        driftButton.setScale(driftDown ? 0.9 : 1)
        driftButton.alpha = driftDown ? 1 : 0.88
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if let finalButton = finalButton, finalButton.contains(point) {
                audio.play("click")
                model?.leaveToMenu()
                return
            }
            if menuButton.contains(point) {
                audio.play("click")
                model?.leaveToMenu()
                return
            }
            if resetButton.contains(point) {
                audio.play("click")
                resetCar()
                continue
            }
            if !hornButton.isHidden && hornButton.contains(point) {
                honk()
                continue
            }
            if nitroButton.contains(point) {
                fireNitro()
                continue
            }
            if soundButton.contains(point) {
                audio.isMuted.toggle()
                refreshSoundIcon()
                audio.play("click")
                continue
            }
            if let control = hitControl(at: point) {
                activeTouches[touch] = control
                tickHaptic.impactOccurred(intensity: 0.5)
            }
        }
        refreshPedals()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let control = activeTouches[touch] else { continue }
            let point = touch.location(in: self)
            // Sliding a finger between neighbouring buttons switches to the new one
            if let now = hitControl(at: point), now != control {
                let steering: Set<Control> = [.left, .right]
                if steering.contains(now) == steering.contains(control) {
                    activeTouches[touch] = now
                }
            }
        }
        refreshPedals()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseTouches(touches)
    }

    private func releaseTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            activeTouches[touch] = nil
            wheelStartX[touch] = nil
        }
        refreshPedals()
    }

    private func resetCar() {
        guard phase == .driving, !localParked else { return }
        let start = level.starts[slot]
        carPosition = start.position
        heading = start.heading
        velocity = 0
        steer = 0
        gear = .drive
        engaged = false
        parkHold = 0
        tickHaptic.impactOccurred()
        world?.follow(position: carPosition, heading: heading, dt: 0, snap: true)
        updateCarNodes()
    }

    // MARK: Update loop

    override func update(_ currentTime: TimeInterval) {
        let started = CACurrentMediaTime()
        gameUpdate(currentTime)
        FrameMonitor.shared.recordUpdate(milliseconds: (CACurrentMediaTime() - started) * 1000)
    }

    private var firstUpdateLogged = false

    private func gameUpdate(_ currentTime: TimeInterval) {
        if !firstUpdateLogged {
            firstUpdateLogged = true
            stage("first update, paused=\(isPaused) viewPaused=\(view?.isPaused ?? true)")
        }
        let rawDelta = lastUpdate == 0 ? 1.0 / 60.0 : currentTime - lastUpdate
        lastUpdate = currentTime
        guard builtSize != .zero else { return }
        var dt = CGFloat(min(max(rawDelta, 0), 1.0 / 30.0))
        // Slow motion while the finish camera watches the car arrive
        if finishAnimating {
            finishClock += dt
            dt *= finishClock < 1.0 ? 0.35 : min(1, 0.35 + (finishClock - 1.0) * 1.6)
        }
        if benchmark { runAutopilot(dt) }

        let leftDown = isPressed(.left)
        let rightDown = isPressed(.right)
        let steerTarget: CGFloat = leftDown == rightDown ? 0 : (leftDown ? 1 : -1)
        wheelInput = approach(wheelInput, steerTarget, (steerTarget == 0 ? 4.0 : 2.6) * dt)

        switch phase {
        case .countdown:
            guard ready else { break }
            let before = Int(ceil(countdown))
            // -slowcountdown (simulator screenshots only): four times slower so every stage is caught
            countdown -= dt * (ParkingScene.slowCountdown ? 0.25 : 1)
            let after = Int(ceil(countdown))
            if countdown <= 0 {
                phase = .driving
                traffic?.racersReleased = true
                challengeCard.run(.sequence([.wait(forDuration: 2.2), .fadeAlpha(to: 0, duration: 0.4)]))
                setCountdown(Strings.go)
                popCountdown(go: true)
                tickHaptic.impactOccurred(intensity: 1.0)
                audio.play("go", volume: 0.7)
            } else {
                if after != before {
                    setCountdown("\(after)")
                    popCountdown(go: false)
                    tickHaptic.impactOccurred()
                    audio.play("beep", volume: 0.6)
                }
                updateCountdownRing()
            }
        case .driving:
            if !localParked {
                elapsed += TimeInterval(dt)
                stepCar(dt)
                separateFromRemote(dt)
                updateGhost()
                if !benchmark { checkParking(dt) }
            }
        case .finished:
            braking = false
            // Roll on past the finish line and slow down
            if level.race && abs(velocity) > 0.5 {
                velocity = approach(velocity, 0, 55 * dt)
                let next = CGPoint(x: carPosition.x + cos(heading) * velocity * dt, y: carPosition.y + sin(heading) * velocity * dt)
                if contacts(OBB(center: next, size: Levels.carSize, angle: heading)).isEmpty {
                    carPosition = next
                } else {
                    velocity = 0
                }
                braking = true
            }
        }

        // Revving is allowed during the countdown too
        let pedal = (isPressed(.forward) || isPressed(.reverse)) && (phase == .driving || phase == .countdown) && !localParked
        updateGearbox(dt, throttle: pedal)
        audio.setMotor(active: true, rpm: Float(rpm), load: pedal ? 1 : (isBoosting ? 0.8 : 0.15))

        if online && friendPresent {
            sendClock += TimeInterval(dt)
            let interval = model?.net.fastActive == true ? 1.0 / 60.0 : 1.0 / 30.0
            if sendClock >= interval && !localParked {
                // Subtracted, not reset, so the states leave at an even pace
                sendClock = min(sendClock - interval, interval)
                sendState()
            }
            pingClock += TimeInterval(dt)
            if pingClock >= 2 {
                pingClock = 0
                model?.sendFast(["t": "pi", "ts": CACurrentMediaTime()])
            }
        }

        if worldFrozen {
            setTimerText(String(format: "%.1f", localParked ? max(localTime, 0) : elapsed))
            return
        }
        if let traffic = traffic {
            var blockers = [carPosition]
            if friendPresent && remoteTarget != nil { blockers.append(remotePosition) }
            if let people = pedestrians {
                // Cars stop for people on the road
                blockers += people.onRoad
                var threats = [PedestrianSystem.Threat(position: carPosition,
                                                       velocity: CGVector(dx: cos(heading) * velocity, dy: sin(heading) * velocity),
                                                       heading: velocity >= 0 ? heading : heading + CGFloat.pi, local: true)]
                if friendPresent && remoteTarget != nil {
                    let v = remoteSnapshots.last?.velocity ?? 0
                    threats.append(PedestrianSystem.Threat(position: remotePosition,
                                                           velocity: CGVector(dx: cos(remoteHeading) * v, dy: sin(remoteHeading) * v),
                                                           heading: v >= 0 ? remoteHeading : remoteHeading + CGFloat.pi, local: false))
                }
                let knocked = people.step(dt, threats: phase == .driving && !localParked ? threats : Array(threats.dropFirst()), horn: pendingHorn)
                pendingHorn = nil
                if knocked > 0 && lastUpdate - lastHitAt > 0.3 {
                    lastHitAt = lastUpdate
                    hits += knocked
                    hitsLabel.text = "\(hits)"
                    velocity *= 0.6
                    bumpHaptic.impactOccurred(intensity: 0.8)
                    audio.play("bump", volume: 0.6)
                    flashBonus(Strings.pedestrianHit)
                    dispatchPolice(Strings.crimePedestrian)
                }
                updatePedestrianNodes()
            }
            traffic.step(dt, blockers: blockers, playerCars: friendPresent && remoteTarget != nil ? 2 : 1)
            // A driver stuck behind us honks (heard within about 40 m)
            for honk in traffic.honks where honk.distance(to: carPosition) < 400 {
                audio.play("horn", volume: Float(max(0.15, 0.55 - honk.distance(to: carPosition) / 900)))
            }
            world?.updateSignals(time: traffic.clock)
            updateArcade(dt, traffic: traffic)
            let detailRange = PerfSettings.carDetailDistance * 10
            var botDetailChanges = 0
            let sweeping = world?.isSweeping ?? false
            let hideBeyond = world?.hiddenBeyond ?? .greatestFiniteMagnitude
            for (index, bot) in traffic.bots.enumerated() where index < botCars.count {
                // In the fog past the far plane: hidden and not posed (nothing to see)
                let viewer = spectateClock > 1.4 ? remotePosition : carPosition
                let dx = bot.position.x - viewer.x, dy = bot.position.y - viewer.y
                let far = !sweeping && dx * dx + dy * dy > hideBeyond * hideBeyond
                if botCars[index].node.isHidden != far { botCars[index].node.isHidden = far }
                if far { continue }
                // (a little further to drop the detail than to add it: a car driving along the edge
                // of the range no longer blinks its lights on and off)
                let reach = botCars[index].showsDetail ? detailRange * 1.15 : detailRange
                let near = sweeping
                    || (abs(bot.position.x - carPosition.x) < reach && abs(bot.position.y - carPosition.y) < reach)
                if botCars[index].setDetail(near) { botDetailChanges += 1 }
                botCars[index].update(position: bot.position, heading: bot.heading, steer: 0, braking: bot.braking)
                if index < hunterHazard.count && hunterHazard[index] != bot.hazard {
                    hunterHazard[index] = bot.hazard
                    botCars[index].setHazard(bot.hazard, sign: level.taxi != nil ? Car3D.taxiSign : Car3D.huntSign)
                }
            }
            if spotWars { updateSpotWars(traffic) }
            if level.taxi != nil { updateTaxi(traffic, dt) }
            if level.race && !level.racers.isEmpty { updateRace(traffic, dt) }
            if benchmark && botDetailChanges > 0 { FrameMonitor.shared.mark("botDetail\(botDetailChanges)") }
            if online && friendPresent && isHost {
                botSendClock += TimeInterval(dt)
                if botSendClock >= 0.125 {
                    botSendClock = 0
                    model?.send(["t": "b", "l": levelIndex, "d": traffic.snapshot()])
                }
            }
        }
        if isCity { updateNavigation(dt) }
        detailClock -= dt
        if detailClock <= 0 {
            detailClock = 0.2
            let parkedChanges = world?.updateDetail(around: spectateClock > 1.4 ? remotePosition : carPosition) ?? 0
            if benchmark && parkedChanges > 0 { FrameMonitor.shared.mark("parkedDetail\(parkedChanges)") }
        }

        if online && friendPresent && remoteParked && !localParked && phase == .driving {
            giveUp -= dt
            statusLabel.text = Strings.friendParkedHurry(max(0, Int(ceil(giveUp))))
            if giveUp <= 0 { gaveUp() }
        }

        updateRemoteCar(dt)
        updateNitro(dt)
        updateBonuses()
        updateSpeedometer(dt)

        updateChallenge(dt)
        if let limit = challenge.timeLimit, !localParked {
            let left = max(0, Double(limit) - elapsed)
            setTimerText(String(format: "%.1f", left))
            let urgent = left < 5
            timerLabel.fontColor = urgent ? UIColor(red: 1, green: 0.35, blue: 0.3, alpha: 1) : UIColor(red: 1, green: 0.86, blue: 0.45, alpha: 1)
        } else {
            setTimerText(String(format: "%.1f", localParked ? localTime : elapsed))
        }
        // While drifting the camera looks between where the car points and where it goes
        let cameraHeading = drifting ? travelHeading + CGFloat.angleDelta(travelHeading, heading) * 0.35 : heading
        let spectating = online && friendPresent && localParked && !remoteParked && !resultsShown && localTime >= 0
        spectateClock = spectating ? spectateClock + dt : 0
        if busted {
            world?.bustedShot(position: carPosition, heading: heading, t: bustedClock)
        } else if spectateClock > 1.4 {
            // Watching the friend through TV-style cameras
            if let last = spectateLast, dt > 0 {
                spectateSpeed += (remotePosition.distance(to: last) / dt - spectateSpeed) * min(1, dt * 3)
            }
            spectateLast = remotePosition
            if spectateOverlay == nil { showSpectateOverlay() }
            // Only the rival and the broadcast frame: no pedals, buttons or our speedometer
            controlsLayer.removeAllActions()
            controlsLayer.alpha = 0
            hud.removeAllActions()
            hud.alpha = 0
            let cut = world?.spectate(position: remotePosition, heading: remoteHeading, speed: spectateSpeed, dt: dt) ?? false
            if cut { spectateCut() }
            if statusLabel.text != "" { statusLabel.text = "" }
        } else {
            if spectateOverlay != nil { hideSpectateOverlay() }
            world?.follow(position: carPosition, heading: cameraHeading, dt: dt)
        }
        updateCarNodes()
        updateSteerGauge()
        updateRain(dt)
    }

    // MARK: - Challenge

    /// Patrol cars of the level: 3D cars on their lanes, with boxes after the level's obstacles.
    private func setupPatrols(_ world: World3D) {
        patrolCars.removeAll()
        patrolBoxStart = obstacleBoxes.count
        for (index, lane) in challenge.patrols.enumerated() {
            let car = Car3D(color: CarArt.parkedColors[(index * 3 + 2) % CarArt.parkedColors.count], style: .sedan, parked: false,
                            variety: 17 + index)
            world.addLevelNode(car.node)
            let patrol = PatrolCar(lane: lane, car: car, topSpeed: challenge.patrolSpeed, phase: index == 0 ? 0.5 : 0.15)
            LeakWatch.track(car, "Car3D")
            LeakWatch.track(patrol, "PatrolCar")
            patrolCars.append(patrol)
            obstacleBoxes.append(patrol.box)
        }
        showChallengeCard()
    }

    /// Time limit, crash limit and the patrol cars, every frame.
    private func updateChallenge(_ dt: CGFloat) {
        let hitsText = challenge.maxHits.map { "\(hits)/\($0)" } ?? "\(hits)"
        if hitsLabel.text != hitsText { hitsLabel.text = hitsText }
        if phase == .driving {
            let mine = OBB(center: carPosition, size: Levels.carSize, angle: heading)
            for (index, patrol) in patrolCars.enumerated() {
                let stopped = patrol.step(dt) { [unowned self] box in
                    box.intersects(mine) || (self.friendPresent && self.remoteTarget != nil && box.intersects(self.remoteBox))
                }
                obstacleBoxes[patrolBoxStart + index] = patrol.box
                if stopped && lastUpdate - patrolHornAt > 3 {
                    patrolHornAt = lastUpdate
                    audio.play("horn", volume: 0.45)
                }
            }
        }
        // Benchmark builds (-policetest): the police called a few seconds in, with a status line
        // and a bonus text up at the same time, for a screenshot of the stacked HUD
        if benchmark && ParkingScene.policeTest && !policeTestDone && phase == .driving && level.city != nil && elapsed > 4 {
            policeTestDone = true
            dispatchPolice(Strings.crimeCrash)
            statusLabel.text = Strings.friendParkedHurry(18)
            flashBonus(Strings.crimeCrash)
            // Tells the check the HUD is up (the screen itself is taken from outside)
            run(.wait(forDuration: 0.6)) { Task { @MainActor in saveWindowSnapshot(named: "shot-police") } }
        }
        // Benchmark builds (-cardtest): the last card of a match won after failing the last round
        // Benchmark builds (-parkedtest): the parked ticket and stamp, frames saved by the app
        if benchmark && ParkingScene.parkedTest && !policeTestDone && phase == .driving && elapsed > 2 {
            policeTestDone = true
            phase = .finished
            localParked = true
            localTime = 23.7
            hits = 1
            newBest = true
            // Into the bay, a few centimetres off and a touch crooked
            let spot = level.spots[slot]
            carPosition = CGPoint(x: spot.center.x - sin(spot.angle) * 0.4, y: spot.center.y + cos(spot.angle) * 0.4)
            heading = spot.angle + 0.008
            velocity = 0
            localCar?.update(position: carPosition, heading: heading, steer: 0)
            lastPrecision = ParkPrecision(spot: spot, car: carPosition, heading: heading, carSize: Levels.carSize)
            playParkedSequence()
            for at in [0.5, 1.0, 1.8, 2.7, 3.4, 4.3] {
                run(.wait(forDuration: at)) { Task { @MainActor in saveWindowSnapshot(named: "shot-parked-\(Int(at * 10))") } }
            }
        }
        if benchmark && ParkingScene.cardTest && !policeTestDone && phase == .driving && elapsed > 2 {
            policeTestDone = true
            phase = .finished
            resultsShown = true
            controlsLayer.alpha = 0
            hud.alpha = 0
            model?.results = ResultsInfo(levelIndex: levelIndex, levelTitle: Levels.title(levelIndex, online: onlineMatch) + " · " + level.name,
                                         entries: [ResultEntry(name: Strings.you, slot: 0, time: nil, hits: 15, isMe: true, isWinner: false, score: -1),
                                                   ResultEntry(name: Strings.friend, slot: 1, time: 31.9, hits: 10, isMe: false, isWinner: true, score: 61.9)],
                                         footer: .final, newBest: false, bestTime: nil, headline: Strings.youWon,
                                         scoreLine: Strings.score(2, 1), reward: nil, outcome: .champion, roundLine: Strings.lastRoundFailed)
            run(.wait(forDuration: 1.2)) { Task { @MainActor in saveWindowSnapshot(named: "shot-card") } }
            return
        }
        // Benchmark builds (-failtest): a level failed two seconds in, for a screenshot of the card
        if benchmark && ParkingScene.failTest && phase == .driving && !localParked && !level.race && elapsed > 2 {
            fail(Strings.tooManyHits)
            run(.wait(forDuration: 1.5)) { Task { @MainActor in saveWindowSnapshot(named: "shot-fail") } }
            return
        }
        guard phase == .driving, !localParked, !benchmark, !level.race else { return }
        if let maxHits = challenge.maxHits {
            if hits > maxHits {
                fail(Strings.tooManyHits)
                return
            }
            if maxHits > 0 && hits == maxHits && !lastHitWarned {
                lastHitWarned = true
                flashBonus(Strings.lastHit)
            }
        }
        if let limit = challenge.timeLimit, elapsed > Double(limit) {
            fail(Strings.timeUp)
        }
    }

    private func fail(_ reason: String) {
        failReason = reason
        flashBonus(reason)
        gaveUp()
    }

    /// The level's rules over the countdown: one slim chip under the top bar (difficulty in its
    /// colour, then the rules), gone a moment after the start.
    private func showChallengeCard() {
        challengeCard.removeAllActions()
        challengeCard.removeAllChildren()
        challengeCard.removeFromParent()
        guard challenge.number > 0 else { return }
        let colors = [UIColor(red: 0.35, green: 0.9, blue: 0.55, alpha: 1), UIColor(red: 1, green: 0.84, blue: 0.3, alpha: 1),
                      UIColor(red: 1, green: 0.55, blue: 0.25, alpha: 1), UIColor(red: 1, green: 0.32, blue: 0.35, alpha: 1),
                      UIColor(red: 0.78, green: 0.45, blue: 1, alpha: 1)]
        let color = colors[min(challenge.tier, colors.count - 1)]
        let tier = makeLabel(challenge.tierName, size: 12, color: color, font: "Barlow-ExtraBold")
        tier.horizontalAlignmentMode = .left
        let rules = makeLabel(challenge.rules.map { $0.text }.joined(separator: "  ·  "), size: 12,
                              color: UIColor.white.withAlphaComponent(0.85), font: "Barlow-SemiBold")
        rules.horizontalAlignmentMode = .left
        let gap: CGFloat = rules.text?.isEmpty == false ? 12 : 0
        let width = tier.frame.width + gap + rules.frame.width + 32
        let glass = makeGlass(width: width, height: 28)
        challengeCard.addChild(glass)
        tier.position = CGPoint(x: -width / 2 + 16, y: 0)
        challengeCard.addChild(tier)
        rules.position = CGPoint(x: tier.position.x + tier.frame.width + gap, y: 0)
        challengeCard.addChild(rules)
        challengeCard.position = CGPoint(x: size.width / 2 + 40, y: size.height - 24 - 40)
        challengeCard.zPosition = 120
        challengeCard.alpha = 0
        addChild(challengeCard)
        challengeCard.run(.fadeIn(withDuration: 0.3))
    }

    // MARK: - Rain

    private var isRaining: Bool { level.weather == .rain }
    private var isSnowing: Bool { level.weather == .snow }

    /// How the road holds the tyres, as in real life: dry asphalt, wet (less side grip, longer
    /// braking, a little wheelspin, floating at speed) or snow (much less of everything, slower
    /// steering response).
    private struct Surface {
        let grip: CGFloat
        let brake: CGFloat
        let traction: CGFloat
        let steer: CGFloat
        let rear: CGFloat
        static let dry = Surface(grip: 1, brake: 1, traction: 1, steer: 1, rear: 1)
        static let wet = Surface(grip: 0.72, brake: 0.72, traction: 0.88, steer: 0.92, rear: 0.62)
        static let snow = Surface(grip: 0.46, brake: 0.48, traction: 0.62, steer: 0.78, rear: 0.42)
    }
    private var surface: Surface { isSnowing ? .snow : (isRaining ? .wet : .dry) }
    private var lightningClock: CGFloat = 6
    private var lensClock: CGFloat = 0
    private let lensLayer = SKNode()
    private let flashOverlay = SKSpriteNode(color: UIColor(red: 0.85, green: 0.9, blue: 1, alpha: 1), size: .zero)

    /// Splashes follow the camera, the rear wheels throw water, drops land on the "lens", and
    /// now and then lightning lights the city.
    private func updateRain(_ dt: CGFloat) {
        guard isRaining || isSnowing else { return }
        world?.updateRain()
        localCar?.setSpray(abs(velocity) / maxForward * (isSnowing ? 0.7 : 1))
        guard isRaining else { return }
        // Now and then a single drop on the lens (a calm rain, not a storm)
        lensClock -= dt
        if lensClock <= 0 && lensLayer.children.count < 4 {
            lensClock = CGFloat.random(in: 1.2...3.2)
            addLensDrop()
        }
    }

    private func haptic(_ intensity: CGFloat) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: intensity)
    }

    /// A water drop on the screen: lands, sits a moment, and runs down.
    private func addLensDrop() {
        let drop = SKSpriteNode(texture: ParkingScene.dropTexture)
        let radius = CGFloat.random(in: 4...9)
        drop.size = CGSize(width: radius * 2, height: radius * 2.2)
        drop.position = CGPoint(x: CGFloat.random(in: 0...size.width), y: CGFloat.random(in: size.height * 0.25...size.height))
        drop.alpha = 0
        drop.setScale(0.6)
        lensLayer.addChild(drop)
        let sit = TimeInterval.random(in: 0.4...1.6)
        let run = TimeInterval.random(in: 0.9...1.8)
        drop.run(.sequence([
            .group([.fadeAlpha(to: CGFloat.random(in: 0.3...0.5), duration: 0.12), .scale(to: 1, duration: 0.12)]),
            .wait(forDuration: sit),
            .group([.moveBy(x: CGFloat.random(in: -8...8), y: -CGFloat.random(in: 60...160), duration: run),
                    .scaleX(to: 0.7, y: 1.25, duration: run),
                    .sequence([.wait(forDuration: run * 0.5), .fadeOut(withDuration: run * 0.5)])]),
            .removeFromParent()]))
    }

    private static let dropTexture: SKTexture = SKTexture(image: CarArt.image(CGSize(width: 40, height: 44), scale: 2) { context, s in
        let rect = CGRect(x: 2, y: 2, width: s.width - 4, height: s.height - 4)
        // Body: a lens that darkens toward the bottom edge, a bright rim and a highlight
        let body = [UIColor(white: 1, alpha: 0.10).cgColor, UIColor(white: 0.1, alpha: 0.28).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: body, locations: [0, 1]) {
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: s.height), options: [])
            context.restoreGState()
        }
        context.setStrokeColor(UIColor(white: 1, alpha: 0.45).cgColor)
        context.setLineWidth(1.2)
        context.strokeEllipse(in: rect.insetBy(dx: 0.6, dy: 0.6))
        context.setFillColor(UIColor(white: 1, alpha: 0.85).cgColor)
        context.fillEllipse(in: CGRect(x: s.width * 0.28, y: s.height * 0.2, width: s.width * 0.2, height: s.height * 0.14))
    })

    /// Puts the rain HUD layers in place for the level (empty and hidden when it is dry).
    private func setupRainLayers() {
        lensLayer.removeAllChildren()
        lensLayer.removeFromParent()
        flashOverlay.removeFromParent()
        guard isRaining else { return }
        lensLayer.zPosition = 40
        addChild(lensLayer)
        flashOverlay.size = CGSize(width: size.width * 2, height: size.height * 2)
        flashOverlay.position = CGPoint(x: size.width / 2, y: size.height / 2)
        flashOverlay.zPosition = 45
        flashOverlay.blendMode = .add
        flashOverlay.alpha = 0.002
        addChild(flashOverlay)
        lightningClock = CGFloat.random(in: 4...9)
    }

    /// The timer label only redraws when its text changes (ten times a second, not every frame).
    private func setTimerText(_ text: String) {
        if timerLabel.text != text { timerLabel.text = text }
    }

    private func updateSteerGauge() {
        let amount = max(-1, min(1, steer / maxSteer))
        let step = abs(amount) < 0.03 ? 0 : Int((amount * 80).rounded())
        guard step != shownSteerStep else { return }
        shownSteerStep = step
        if step == 0 {
            steerArc.path = nil
            if steerLabel.text != "" { steerLabel.text = "" }
            return
        }
        // Left fills toward the left side of the bar
        let width = CGFloat(abs(step))
        let rect = step > 0 ? CGRect(x: -width, y: -3.5, width: width, height: 7) : CGRect(x: 0, y: -3.5, width: width, height: 7)
        steerArc.path = CGPath(roundedRect: rect, cornerWidth: min(3.5, width / 2), cornerHeight: 3.5, transform: nil)
        let text = abs(amount) < 0.12 ? "" : (amount > 0 ? "◀ " + Strings.left : Strings.right + " ▶")
        if steerLabel.text != text { steerLabel.text = text }
    }

    // MARK: City race

    private func gaveUp() {
        endPoliceChase()
        audio.setLoop("siren", volume: 0)
        audio.setLoop("wind", volume: 0)
        squealLevel = 0
        audio.setLoop("skid", volume: 0)
        localParked = true
        localTime = -1
        velocity = 0
        braking = false
        phase = .finished
        holdRing.path = nil
        statusLabel.text = ""
        notifyHaptic.notificationOccurred(.error)
        model?.send(["t": "p", "l": levelIndex, "time": -1.0, "hits": hits,
                     "x": Double(carPosition.x), "y": Double(carPosition.y), "h": Double(heading)])
        checkLevelDone()
    }

    // MARK: Rival racers

    static let racerColors: [UIColor] = [UIColor(red: 1, green: 0.25, blue: 0.6, alpha: 1),
                                         UIColor(red: 0.2, green: 0.85, blue: 1, alpha: 1),
                                         UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)]
    private var racePlace: Int?
    private var raceRanks: [Int: CGFloat] = [:]
    private var raceRankClock: CGFloat = 0
    private var raceFinishSeen = 0

    /// Name tags over the rivals; the place chip under the top bar.
    private func setupRacers(_ traffic: Traffic) {
        racePlace = nil
        raceRanks.removeAll()
        raceRankClock = 0
        raceFinishSeen = 0
        guard level.race, !level.racers.isEmpty else { return }
        var k = 0
        for (index, bot) in traffic.bots.enumerated() where bot.racer && index < botCars.count {
            let racer = level.racers[min(k, level.racers.count - 1)]
            botCars[index].setTag(ParkingScene.racerTag(racer.name, color: ParkingScene.racerColors[racer.color % ParkingScene.racerColors.count]))
            k += 1
        }
        updateRaceChip(place: level.racers.count + 1)
    }

    /// A rounded name tag in the racer's colour.
    static func racerTag(_ name: String, color: UIColor) -> UIImage {
        let font = UIFont(name: "BarlowCondensed-BlackItalic", size: 46) ?? UIFont.systemFont(ofSize: 42, weight: .black)
        let text = NSAttributedString(string: name.localUpper, attributes: [.font: font, .foregroundColor: UIColor.white])
        let size = text.size()
        let width = size.width + 56
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: 76)).image { _ in
            let path = UIBezierPath(roundedRect: CGRect(x: 4, y: 6, width: width - 8, height: 64), cornerRadius: 32)
            UIColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 0.85).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 6
            path.stroke()
            text.draw(at: CGPoint(x: (width - size.width) / 2, y: 38 - size.height / 2))
        }
    }

    /// Who crossed the line, and our place (by the drive left to the finish) four times a second.
    private func updateRace(_ traffic: Traffic, _ dt: CGFloat) {
        while raceFinishSeen < traffic.raceFinishes.count {
            let finish = traffic.raceFinishes[raceFinishSeen]
            raceFinishSeen += 1
            if !localParked, let racer = racerFor(bot: finish.bot, traffic) {
                flashBonus(Strings.racerFinished(racer.name))
            }
        }
        guard let city = level.city else { return }
        if localParked {
            if racePlace == nil { racePlace = 1 + traffic.raceFinishes.count }
            return
        }
        raceRankClock -= dt
        guard raceRankClock <= 0 else { return }
        raceRankClock = 0.25
        let goal = level.spots[0].center
        func left(_ p: CGPoint) -> CGFloat {
            let path = city.route(from: p, to: goal)
            return zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        }
        let mine = left(carPosition)
        var ahead = traffic.raceFinishes.count
        var boost: [Int: CGFloat] = [:]
        for (index, bot) in traffic.bots.enumerated() where bot.racer && !bot.raceDone {
            let theirs = left(bot.position)
            if theirs < mine { ahead += 1 }
            // Catch-up: up to a third faster when far behind, a little slower when far ahead
            boost[index] = max(0.85, min(1.35, 1 + (theirs - mine) / 2500))
        }
        traffic.racerBoost = boost
        updateRaceChip(place: ahead + 1)
    }

    private func racerFor(bot index: Int, _ traffic: Traffic) -> RacerStart? {
        var k = 0
        for (i, bot) in traffic.bots.enumerated() where bot.racer || bot.raceDone {
            if i == index { return level.racers.indices.contains(k) ? level.racers[k] : nil }
            k += 1
        }
        return nil
    }

    private func updateRaceChip(place: Int) {
        let text = "🏁 " + Strings.racePlace(place, of: level.racers.count + 1)
        if spotsChip.parent == nil {
            spotsChip.position = chipAnchor
            spotsChip.zPosition = 30
            hud.addChild(spotsChip)
        }
        if spotsChip.name == text { return }
        spotsChip.name = text
        spotsChip.removeAllChildren()
        let label = makeLabel(text, size: 15, color: place == 1 ? UIColor(red: 1, green: 0.84, blue: 0.3, alpha: 1) : .white, font: "Barlow-ExtraBold")
        let glass = makeGlass(width: label.frame.width + 32, height: 30)
        spotsChip.addChild(glass)
        spotsChip.addChild(label)
        alignChip(width: label.frame.width + 32)
    }

    // MARK: Taxi

    private enum TaxiState { case waiting, boarding, riding, lost, delivered }
    private var taxiState = TaxiState.waiting
    private var customerNode: SCNNode?
    private var customerSign: SCNNode?
    private var customerPosition = CGPoint.zero
    private var customerHeading: CGFloat = 0
    private var customerClock: CGFloat = 0
    private var customerWalk: CGFloat = 0
    private var pickHold: CGFloat = 0
    private var boardTarget = CGPoint.zero
    private var rideStartedAt: Double = 0
    private var ridePar: CGFloat = 0
    private var spill: CGFloat = 0
    private var rideDriftStart = 0
    private var tipLostReason: String?
    private var taxiEscaped = false
    private var lastRideVelocity: CGFloat = 0
    private var lastRideHeading: CGFloat = 0
    private(set) var taxiFare = 0
    private(set) var taxiTip = 0
    /// Online: when we picked the customer up (seconds into the round), to settle a close call.
    private var pickedAt: Double = -1
    private var taxiTestPlaced = false

    /// The customer at the kerb: a person with a sign over their head saying what they want.
    private func setupTaxi(_ world: World3D) {
        customerNode?.removeFromParentNode()
        customerSign?.removeFromParentNode()
        customerNode = nil
        customerSign = nil
        taxiState = .waiting
        pickHold = 0
        spill = 0
        tipLostReason = nil
        taxiEscaped = false
        taxiFare = 0
        taxiTip = 0
        pickedAt = -1
        guard let taxi = level.taxi else { return }
        customerPosition = taxi.customer
        customerHeading = taxi.facing
        customerClock = 0
        let node = SCNNode()
        world.addLevelNode(node)
        customerNode = node
        let signPlane = SCNPlane(width: 3.3, height: 2.4)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = ParkingScene.customerSignImage(taxi.rider)
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        signPlane.materials = [material]
        let sign = SCNNode(geometry: signPlane)
        sign.renderingOrder = 50
        sign.constraints = [SCNBillboardConstraint()]
        sign.runAction(.repeatForever(.sequence([.moveBy(x: 0, y: 0.3, z: 0, duration: 0.5), .moveBy(x: 0, y: -0.3, z: 0, duration: 0.5)])))
        world.addLevelNode(sign)
        customerSign = sign
        poseCustomer()
        spotsChip.name = nil
        level.spots[slot] = level.freeSpots.first?.def ?? level.spots[slot]
        world.setSpotTarget(0, center: level.spots[slot].center)
        updateTaxiChip()
    }

    /// A speech bubble: "TAXI!" and the icon of what the customer wants.
    static func customerSignImage(_ rider: Rider) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 208, height: 152)).image { _ in
            let bubble = UIBezierPath(roundedRect: CGRect(x: 6, y: 6, width: 196, height: 112), cornerRadius: 26)
            bubble.move(to: CGPoint(x: 88, y: 116))
            bubble.addLine(to: CGPoint(x: 104, y: 146))
            bubble.addLine(to: CGPoint(x: 120, y: 116))
            UIColor(red: 1, green: 0.8, blue: 0.1, alpha: 1).setFill()
            bubble.fill()
            UIColor.white.setStroke()
            bubble.lineWidth = 6
            bubble.stroke()
            let font = UIFont(name: "BarlowCondensed-BlackItalic", size: 46) ?? UIFont.systemFont(ofSize: 42, weight: .black)
            let ink = UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
            let word = NSAttributedString(string: "TAXI!", attributes: [.font: font, .foregroundColor: ink])
            let icon = NSAttributedString(string: rider.icon, attributes: [.font: UIFont.systemFont(ofSize: 50)])
            let w = word.size(), i = icon.size()
            let total = w.width + 10 + i.width
            icon.draw(at: CGPoint(x: 104 - total / 2, y: 62 - i.height / 2))
            word.draw(at: CGPoint(x: 104 - total / 2 + i.width + 10, y: 62 - w.height / 2))
        }
    }

    private func poseCustomer() {
        guard let node = customerNode, let taxi = level.taxi else { return }
        let near = customerPosition.distance(to: carPosition) < 320
        let clip: PedestrianModels.Clip
        switch taxiState {
        case .waiting: clip = near ? .angry : .idle          // waving once we come close
        case .boarding, .lost: clip = .walk
        default: clip = .idle
        }
        let outfit = (levelIndex + Rider.allCases.count + taxi.rider.rawValue) % PedestrianModels.outfitCount
        let geometry = clip == .walk
            ? PedestrianModels.geometry(character: outfit, clip: .walk, phase: customerWalk / PedestrianModels.walkCycle)
            : PedestrianModels.geometry(character: outfit, clip: clip, time: customerClock)
        if let geometry = geometry, node.geometry !== geometry { node.geometry = geometry }
        var p = World3D.vec(customerPosition)
        p.y = Float(level.city?.kerbHeight(at: customerPosition) ?? 0)
        node.position = p
        node.eulerAngles = SCNVector3(0, Float(customerHeading), 0)
        customerSign?.position = SCNVector3(p.x, p.y + 5.4, p.z)
    }

    /// The pick-up (stop by the customer before a rival taxi does), the walk to the car, the
    /// ride (what the customer wants decides the tip) and the drop-off at the destination bay.
    private func updateTaxi(_ traffic: Traffic, _ dt: CGFloat) {
        guard let taxi = level.taxi else { return }
        customerClock += dt
        // A rival taxi pulled up at the customer first
        for take in traffic.takes where take.spot == 0 {
            if online && friendPresent && isHost {
                model?.send(["t": "take", "l": levelIndex, "s": 0, "b": take.bot])
            }
            rivalGotCustomer(bot: take.bot)
        }
        switch taxiState {
        case .waiting:
            guard phase == .driving else { break }
            let close = carPosition.distance(to: taxi.customer) < 95 && abs(velocity) < 16
            pickHold = close ? pickHold + dt : 0
            if pickHold > 0.5 {
                startBoarding(to: carPosition)
                pickedAt = elapsed
                traffic.claim(0)
                if online && friendPresent {
                    model?.send(["t": "pick", "l": levelIndex, "at": elapsed])
                }
            }
        case .boarding, .lost:
            let dx = boardTarget.x - customerPosition.x, dy = boardTarget.y - customerPosition.y
            let d = hypot(dx, dy)
            let step = min(d, 26 * dt)
            if d > 1 {
                customerPosition.x += dx / d * step
                customerPosition.y += dy / d * step
                customerHeading = atan2(dy, dx)
                customerWalk += step
            }
            if d < 14 {
                customerNode?.isHidden = true
                customerSign?.isHidden = true
                if taxiState == .boarding { startRide(taxi) }
            }
        case .riding:
            updateRide(taxi, dt)
        case .delivered:
            break
        }
        if customerNode?.isHidden == false { poseCustomer() }
    }

    private func startBoarding(to point: CGPoint) {
        taxiState = .boarding
        boardTarget = point
        audio.play("click", volume: 0.5)
        flashBonus(Strings.customerComing)
    }

    private func startRide(_ taxi: TaxiDef) {
        taxiState = .riding
        rideStartedAt = elapsed
        rideDriftStart = runDriftPoints
        lastRideVelocity = velocity
        lastRideHeading = heading
        notifyHaptic.notificationOccurred(.success)
        // The bay moves to the destination
        world?.clearFreeSpots()
        world?.buildFreeSpots([taxi.destination])
        level.spots[slot] = taxi.destination
        world?.setSpotTarget(0, center: taxi.destination.center)
        routeClock = 0
        if let city = level.city {
            let path = city.route(from: carPosition, to: taxi.destination.center)
            let length = zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
            ridePar = (length / 170 + 9).rounded()
        }
        flashBonus(Strings.riderLine(taxi.rider))
        if taxi.rider == .getaway { dispatchPolice(Strings.crimeGetaway) }
        updateTaxiChip()
    }

    /// The ride: the clock for a hurried customer, the cup for the coffee, the drifts for the
    /// show-off; the chip shows how it goes.
    private func updateRide(_ taxi: TaxiDef, _ dt: CGFloat) {
        let accel = abs(velocity - lastRideVelocity) / max(dt, 0.001)
        let turn = abs(CGFloat.angleDelta(lastRideHeading, heading)) / max(dt, 0.001) * abs(velocity)
        lastRideVelocity = velocity
        lastRideHeading = heading
        switch taxi.rider {
        case .hurry:
            if tipLostReason == nil && CGFloat(elapsed - rideStartedAt) > ridePar { loseTip(Strings.riderLate) }
        case .coffee:
            if tipLostReason == nil {
                spill += max(0, accel - 230) * dt * 0.09 + max(0, turn - 260) * dt * 0.05
                spill = max(0, spill - dt * 2)
                if spill >= 100 { loseTip(Strings.riderSpilled) }
            }
        case .show, .getaway:
            break
        }
        updateTaxiChip()
    }

    /// The customer's tip is gone (late, coffee spilled, caught): a line, no coins for it.
    private func loseTip(_ reason: String) {
        guard tipLostReason == nil else { return }
        tipLostReason = reason
        flashBonus(reason)
        notifyHaptic.notificationOccurred(.error)
    }

    /// A rival taxi (or, online, the friend) got the customer: they walk over and the round is lost.
    private func rivalGotCustomer(bot: Int?) {
        guard taxiState == .waiting || taxiState == .boarding else { return }
        taxiState = .lost
        if let bot = bot, let position = traffic?.bots.indices.contains(bot) == true ? traffic?.bots[bot].position : nil {
            boardTarget = position
        } else {
            boardTarget = remotePosition
        }
        if !localParked && phase == .driving {
            fail(bot == nil ? Strings.friendGotCustomer : Strings.rivalGotCustomer)
        }
    }

    /// Coins for the ride: the fare by distance, the tip by what the customer wanted and by how
    /// well we parked at the end.
    private func settleTaxi() {
        guard let taxi = level.taxi, taxiState == .delivered else { return }
        let rideLength = level.city.map { city -> CGFloat in
            let path = city.route(from: taxi.customer, to: taxi.destination.center)
            return zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        } ?? 2000
        taxiFare = 20 + Int(rideLength / 100)
        guard tipLostReason == nil else { taxiTip = 0; return }
        var share: CGFloat
        switch taxi.rider {
        case .hurry: share = 0.5 + 0.8 * max(0, 1 - CGFloat(elapsed - rideStartedAt) / max(ridePar, 1))
        case .coffee: share = 0.6 + 0.6 * max(0, 1 - spill / 100)
        case .show: share = min(1.5, CGFloat(runDriftPoints - rideDriftStart) / 600 * 1.5)
        case .getaway: share = taxiEscaped ? 1.5 : 0.4
        }
        let precision = CGFloat(lastPrecision?.score ?? 60) / 100
        taxiTip = Int((CGFloat(taxiFare) * share * (0.4 + 0.6 * precision)).rounded())
    }

    /// Under the top bar: what to do now and how the customer's wish is going.
    private func updateTaxiChip() {
        guard let taxi = level.taxi else { return }
        let text: String
        var urgent = false
        switch taxiState {
        case .waiting, .boarding, .lost:
            text = "🙋 " + Strings.pickUpCustomer
        case .riding, .delivered:
            if let lost = tipLostReason {
                text = taxi.rider.icon + " " + lost
                urgent = true
            } else {
                switch taxi.rider {
                case .hurry:
                    let left = max(0, Int((ridePar - CGFloat(elapsed - rideStartedAt)).rounded(.up)))
                    text = "⏱ " + Strings.riderTimeLeft(left)
                    urgent = left <= 5
                case .coffee:
                    text = "☕ " + Strings.riderCup(Int(spill))
                    urgent = spill > 70
                case .show:
                    text = "🌀 " + Strings.riderDrift(runDriftPoints - rideDriftStart, 600)
                case .getaway:
                    text = "🚨 " + (taxiEscaped ? Strings.policeEscaped : Strings.riderLoseThem)
                    urgent = !taxiEscaped && police != nil
                }
            }
        }
        if spotsChip.parent == nil {
            spotsChip.position = chipAnchor
            spotsChip.zPosition = 30
            hud.addChild(spotsChip)
        }
        if spotsChip.name == text { return }
        spotsChip.name = text
        spotsChip.removeAllChildren()
        let label = makeLabel(text, size: 14, color: urgent ? UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1) : .white, font: "Barlow-ExtraBold")
        let glass = makeGlass(width: label.frame.width + 32, height: 30)
        spotsChip.addChild(glass)
        spotsChip.addChild(label)
        alignChip(width: label.frame.width + 32)
    }

    // MARK: Spot Wars

    /// Bays hunters took this frame (the host tells the guest), the bay we head for (the nearest
    /// one still free), and the round lost once every bay is gone.
    private func updateSpotWars(_ traffic: Traffic) {
        for take in traffic.takes {
            spotGone(take.spot, byHunter: true)
            if online && friendPresent && isHost {
                model?.send(["t": "take", "l": levelIndex, "s": take.spot, "b": take.bot])
            }
        }
        guard !localParked, phase == .driving || phase == .countdown else { return }
        let free = level.freeSpots.indices.filter { !traffic.taken.contains($0) }
        if free.isEmpty {
            if !spotsGoneFailed && phase == .driving {
                spotsGoneFailed = true
                fail(Strings.noSpotsLeft)
            }
            return
        }
        let nearest = free.min { level.freeSpots[$0].def.center.distance(to: carPosition) < level.freeSpots[$1].def.center.distance(to: carPosition) }!
        if nearest != spotTarget { aim(at: nearest) }
    }

    private func aim(at index: Int) {
        spotTarget = index
        let def = level.freeSpots[index].def
        level.spots[slot] = def
        world?.setSpotTarget(index, center: def.center)
        routeClock = 0
        for (k, pin) in freeSpotPins.enumerated() where k < level.freeSpots.count {
            pin.setScale(k == index ? 1.35 : 1)
        }
    }

    /// A bay is gone (to a hunter, or to the friend): its light goes out, its pin goes, the chip
    /// counts down, and we head for another one if it was ours.
    private func spotGone(_ index: Int, byHunter: Bool) {
        guard level.freeSpots.indices.contains(index) else { return }
        traffic?.claim(index)
        world?.markSpotTaken(index)
        if index < freeSpotPins.count {
            freeSpotPins[index].run(.sequence([.scale(to: 0.1, duration: 0.25), .hide()]))
        }
        updateSpotsChip()
        guard !localParked, phase == .driving else { return }
        let left = traffic?.freeSpotCount ?? 0
        if index == spotTarget {
            spotTarget = -1
            if left > 0 {
                flashBonus(byHunter ? Strings.yourSpotTaken : Strings.friendTookSpot)
                notifyHaptic.notificationOccurred(.warning)
            }
        } else if left == 1 {
            flashBonus(Strings.lastSpot)
        } else if byHunter {
            flashBonus(Strings.spotTaken)
        }
    }

    /// The mode chip's home: under the speed dial, its left edge with the dial's (the middle of
    /// the screen belongs to the police banner and the bonus lines, which it used to sit under).
    private var chipAnchor: CGPoint {
        CGPoint(x: speedDial.position.x - speedRadius, y: speedDial.position.y - speedRadius - 30)
    }

    /// Lays the chip out from its anchor to the right (built centred on it).
    private func alignChip(width: CGFloat) {
        for child in spotsChip.children { child.position.x += width / 2 }
    }

    /// "P  3 free bays" under the top bar (red with one left).
    private func setupSpotsChip() {
        spotsChip.removeAllChildren()
        spotsChip.removeFromParent()
        guard spotWars else { return }
        spotsChip.position = chipAnchor
        spotsChip.zPosition = 30
        hud.addChild(spotsChip)
        updateSpotsChip()
        // The rule, once, under the chip: drivers with hazard lights are after the same bays
        let hint = makeLabel(Strings.spotWarsHint, size: 13, color: UIColor(red: 1, green: 0.8, blue: 0.4, alpha: 1), font: "Barlow-SemiBold")
        hint.name = "spotHint"
        hint.horizontalAlignmentMode = .left
        hint.position = CGPoint(x: chipAnchor.x, y: chipAnchor.y - 28)
        hint.zPosition = 30
        hud.childNode(withName: "spotHint")?.removeFromParent()
        hud.addChild(hint)
        hint.run(.sequence([.wait(forDuration: 9), .fadeOut(withDuration: 0.6), .removeFromParent()]))
    }

    private func updateSpotsChip() {
        guard spotWars else { return }
        spotsChip.removeAllChildren()
        let left = traffic?.freeSpotCount ?? level.freeSpots.count
        let urgent = left <= 1
        let text = makeLabel(Strings.spotsLeft(left), size: 14, color: .white, font: "Barlow-ExtraBold")
        text.horizontalAlignmentMode = .left
        let badgeSize: CGFloat = 20
        let width = badgeSize + 8 + text.frame.width + 26
        let glass = makeGlass(width: width, height: 30)
        spotsChip.addChild(glass)
        let badge = SKShapeNode(circleOfRadius: badgeSize / 2)
        badge.fillColor = urgent ? UIColor(red: 1, green: 0.32, blue: 0.3, alpha: 1) : UIColor(red: 1, green: 0.8, blue: 0.22, alpha: 1)
        badge.strokeColor = .clear
        badge.position = CGPoint(x: -width / 2 + 13 + badgeSize / 2, y: 0)
        spotsChip.addChild(badge)
        let p = makeLabel("P", size: 13, color: UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1), font: "Barlow-Black")
        p.position = badge.position
        spotsChip.addChild(p)
        text.position = CGPoint(x: badge.position.x + badgeSize / 2 + 8, y: 0)
        spotsChip.addChild(text)
        alignChip(width: width)
        spotsChip.removeAction(forKey: "pulse")
        spotsChip.setScale(1)
        if urgent {
            spotsChip.run(.repeatForever(.sequence([.scale(to: 1.08, duration: 0.35), .scale(to: 1, duration: 0.35)])), withKey: "pulse")
        }
    }

    private func updateNavigation(_ dt: CGFloat) {
        guard let city = level.city else { return }
        let target = level.spots[slot].center
        routeClock -= dt
        if routeClock <= 0 || route.isEmpty {
            routeClock = 0.25
            if benchmark { FrameMonitor.shared.mark("route") }
            route = city.route(from: carPosition, to: target)
            // From the first turn on: the piece from the car is drawn every frame (updateMinimap)
            let path = CGMutablePath()
            for (index, point) in route.enumerated().dropFirst() {
                let p = CGPoint(x: point.x * mapScale, y: point.y * mapScale)
                if index == 1 { path.move(to: p) } else { path.addLine(to: p) }
            }
            routeLine.path = path
            routeCasing.path = path
        }
        setNavShown(!localParked && phase != .countdown)
        guard route.count >= 2 else { return }

        // Where to steer right now
        var k = 1
        if route.count > 2 && carPosition.distance(to: route[1]) < 95 { k = 2 }
        let aim = route[k]
        let relative = CGFloat.angleDelta(heading, atan2(aim.y - carPosition.y, aim.x - carPosition.x))
        navArrow.zRotation = relative

        let toTarget = carPosition.distance(to: target)
        if toTarget < 90 {
            navLabel.text = level.race ? Strings.finishLine
                : (level.taxi != nil && taxiState != .riding && taxiState != .delivered ? Strings.pickUpShort : Strings.parkHere)
            return
        }
        if abs(relative) > 2.0 {
            navLabel.text = Strings.uTurn
            return
        }
        // Next turn along the route
        var travelled = carPosition.distance(to: route[k])
        var m = k
        while m < route.count - 1 {
            let a = route[m - 1]
            let b = route[m]
            let c = route[m + 1]
            let turn = CGFloat.angleDelta(atan2(b.y - a.y, b.x - a.x), atan2(c.y - b.y, c.x - b.x))
            if m >= 1 && abs(turn) > 0.6 && m < route.count - 1 && !(m == route.count - 2 && b.distance(to: c) < 140) {
                let meters = Int((travelled / 10).rounded())
                navLabel.text = (turn > 0 ? Strings.turnLeft : Strings.turnRight) + " · \(meters) m"
                return
            }
            travelled += b.distance(to: c)
            m += 1
        }
        navLabel.text = (level.race ? Strings.finishLine : Strings.toTarget) + " · \(Int((toTarget / 10).rounded())) m"
    }

    // MARK: Speedometer

    private let speedRadius: CGFloat = 50
    private let dialStart: CGFloat = CGFloat.pi * 1.25   // lower left
    private let dialSweep: CGFloat = CGFloat.pi * 1.5    // 270 degrees, clockwise
    private let dialMaxKmh: CGFloat = 100

    /// Modern dial: a dark glass disc, a thin tachometer ring of segments that light up with the
    /// revs (warm near the redline, cyan on nitro), a speed bar inside it, the speed in big
    /// numerals and the gear underneath.
    private func buildSpeedometer(left: CGFloat, top: CGFloat) {
        speedDial = SKNode()
        speedDial.position = CGPoint(x: left + speedRadius + 14, y: top - 44 - speedRadius)
        hud.addChild(speedDial)

        let disc = SKShapeNode(circleOfRadius: speedRadius + 6)
        disc.fillColor = UIColor(red: 0.03, green: 0.05, blue: 0.10, alpha: 0.62)
        disc.strokeColor = UIColor.white.withAlphaComponent(0.12)
        disc.lineWidth = 1
        speedDial.addChild(disc)

        // Faint segments of the tachometer ring
        let track = SKShapeNode()
        track.path = tachPath(segments: tachSegments)
        track.strokeColor = UIColor.white.withAlphaComponent(0.10)
        track.lineWidth = 5
        track.lineCap = .butt
        speedDial.addChild(track)

        speedArc = SKShapeNode()
        speedArc.lineWidth = 5
        speedArc.lineCap = .butt
        speedDial.addChild(speedArc)

        // Speed bar: a thin inner arc
        let speedTrack = SKShapeNode()
        let trackPath = CGMutablePath()
        trackPath.addArc(center: .zero, radius: speedRadius - 13, startAngle: dialStart, endAngle: dialStart - dialSweep, clockwise: true)
        speedTrack.path = trackPath
        speedTrack.strokeColor = UIColor.white.withAlphaComponent(0.08)
        speedTrack.lineWidth = 2
        speedTrack.lineCap = .round
        speedDial.addChild(speedTrack)
        speedBar = SKShapeNode()
        speedBar.lineWidth = 2
        speedBar.lineCap = .round
        speedBar.strokeColor = UIColor(red: 0.45, green: 0.88, blue: 0.82, alpha: 1)
        speedDial.addChild(speedBar)

        speedLabel = makeLabel("0", size: 30, color: .white, font: "Barlow-SemiBold")
        speedLabel.position = CGPoint(x: 0, y: 5)
        speedDial.addChild(speedLabel)
        let unit = makeLabel("km/h", size: 9, color: UIColor.white.withAlphaComponent(0.5), font: "Barlow-Medium")
        unit.position = CGPoint(x: 0, y: -13)
        speedDial.addChild(unit)
        dialGear = makeLabel("1", size: 13, color: UIColor(red: 0.45, green: 0.88, blue: 0.82, alpha: 1), font: "Barlow-Bold")
        dialGear.position = CGPoint(x: 0, y: -speedRadius + 4)
        speedDial.addChild(dialGear)
    }

    private let tachSegments = 30
    private var speedBar = SKShapeNode()
    private var dialGear = SKLabelNode()
    private var shownTachStep = -1

    /// The first `count` of the tachometer's segments (small gaps between them).
    private func tachPath(segments count: Int) -> CGPath {
        let path = CGMutablePath()
        let step = dialSweep / CGFloat(tachSegments)
        for index in 0..<count {
            let a0 = dialStart - step * CGFloat(index) - step * 0.12
            let a1 = dialStart - step * CGFloat(index + 1) + step * 0.12
            path.move(to: CGPoint(x: cos(a0) * (speedRadius - 3), y: sin(a0) * (speedRadius - 3)))
            path.addArc(center: .zero, radius: speedRadius - 3, startAngle: a0, endAngle: a1, clockwise: true)
        }
        return path
    }

    /// 1 world unit = 10 cm, so units/s * 0.36 = km/h.
    private func updateSpeedometer(_ dt: CGFloat) {
        let kmh = abs(velocity) * 0.36
        shownSpeed += (kmh - shownSpeed) * min(1, dt * 10)
        let shownKmh = Int(shownSpeed.rounded())
        if shownKmh != lastShownKmh {
            // Label text is drawn into a texture on every change: only when the number changes
            lastShownKmh = shownKmh
            speedLabel.text = "\(shownKmh)"
        }
        let fraction = min(1, shownSpeed / dialMaxKmh)
        let speedStep = fraction > 0.005 ? Int((fraction * 120).rounded()) : -1
        if speedStep != shownSpeedStep {
            shownSpeedStep = speedStep
            if speedStep >= 0 {
                let path = CGMutablePath()
                path.addArc(center: .zero, radius: speedRadius - 13, startAngle: dialStart,
                            endAngle: dialStart - dialSweep * CGFloat(speedStep) / 120, clockwise: true)
                speedBar.path = path
            } else {
                speedBar.path = nil
            }
        }
        // Tachometer: segments lit by the revs
        let revs = max(0, min(1, (rpm - idleRPM) / (redline - idleRPM)))
        let lit = Int((revs * CGFloat(tachSegments)).rounded())
        if lit != shownTachStep {
            shownTachStep = lit
            speedArc.path = lit > 0 ? tachPath(segments: lit) : nil
        }
        let color: UIColor
        if isBoosting {
            color = UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 1)
        } else if revs < 0.7 {
            color = UIColor(white: 0.92, alpha: 1)
        } else if revs < 0.9 {
            color = UIColor(red: 1.0, green: 0.74, blue: 0.5, alpha: 1)
        } else {
            color = UIColor(red: 1.0, green: 0.38, blue: 0.36, alpha: 1)
        }
        speedArc.strokeColor = color
        speedLabel.fontColor = isBoosting ? color : .white
        let gearText = gear == .reverse ? "R" : "\(gearIndex)"
        if dialGear.text != gearText { dialGear.text = gearText }
    }

    // MARK: Minimap

    /// Navigation-style minimap in the top-right corner, heading-up like the camera: the map is
    /// one pre-drawn picture (streets with lane lines, pavements, building footprints, parks; or
    /// the lot with its walls, cars and cones), the route a cased line from the car, a compass
    /// ring that turns with the map, a view cone ahead of the player's arrow, and the distance to
    /// the target. It turns and zooms smoothly (further out at speed) and fades in on a new level.
    private var routeCasing = SKShapeNode()
    private var routeLead = SKShapeNode()
    private var routeLeadCasing = SKShapeNode()
    private var mapCompass = SKNode()
    private var mapHeading: CGFloat = 0
    private var mapZoom: CGFloat = 1
    private var minimapTime: TimeInterval = 0
    private var mapDistance = SKLabelNode()
    private var mapDistanceClock: TimeInterval = 0

    private func buildMinimap() {
        minimap.removeAllChildren()
        botDots.removeAll()
        let right = max(insets.right, 10)
        let radius = mapRadius
        minimap.position = CGPoint(x: size.width - right - radius - 8, y: size.height - 56 - radius)
        codeLabel.position = CGPoint(x: minimap.position.x, y: minimap.position.y - radius - 22)
        mapScale = isCity ? radius / 700 : radius / 420

        // Bezel: a soft shadow, a dark glass disc and a light rim
        let shadow = SKSpriteNode(texture: dotTexture)
        shadow.size = CGSize(width: radius * 2 + 30, height: radius * 2 + 30)
        shadow.color = .black
        shadow.colorBlendFactor = 1
        shadow.alpha = 0.45
        shadow.position = CGPoint(x: 0, y: -3)
        minimap.addChild(shadow)
        let backdrop = SKShapeNode(circleOfRadius: radius + 5)
        backdrop.fillColor = UIColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 0.92)
        backdrop.strokeColor = UIColor.white.withAlphaComponent(0.22)
        backdrop.lineWidth = 1.5
        minimap.addChild(backdrop)

        let crop = SKCropNode()
        let mask = SKShapeNode(circleOfRadius: radius)
        mask.fillColor = .white
        mask.strokeColor = .clear
        crop.maskNode = mask
        minimap.addChild(crop)
        mapContent = SKNode()
        crop.addChild(mapContent)

        // The map itself, drawn once
        let picture = SKSpriteNode(texture: CarArt.minimapTexture(level: level, scale: mapScale))
        picture.anchorPoint = .zero
        picture.size = CGSize(width: level.world.width * mapScale, height: level.world.height * mapScale)
        mapContent.addChild(picture)

        if isCity {
            // Route: a dark casing under a bright core, and the piece from the car to the route
            let core = UIColor(red: 0.36, green: 0.86, blue: 1.0, alpha: 1)
            let casing = UIColor(red: 0.02, green: 0.22, blue: 0.40, alpha: 1)
            routeCasing = SKShapeNode()
            routeLine = SKShapeNode()
            routeLeadCasing = SKShapeNode()
            routeLead = SKShapeNode()
            for (node, color, width) in [(routeCasing, casing, CGFloat(6.5)), (routeLeadCasing, casing, 6.5),
                                         (routeLine, core, 3.6), (routeLead, core, 3.6)] {
                node.strokeColor = color
                node.lineWidth = width
                node.lineCap = .round
                node.lineJoin = .round
                node.isAntialiased = true
                mapContent.addChild(node)
            }
            for bot in traffic?.bots ?? [] {
                let dot = SKSpriteNode(texture: dotTexture)
                // Drivers hunting for a spot show amber and bigger
                let hunter = bot.hunt >= 0
                dot.size = hunter || bot.racer ? CGSize(width: 7, height: 7) : CGSize(width: 4.5, height: 4.5)
                dot.color = bot.racer ? ParkingScene.racerColors[bot.tint % ParkingScene.racerColors.count]
                    : (hunter ? UIColor(red: 1, green: 0.66, blue: 0.12, alpha: 1) : UIColor(white: 0.92, alpha: 1))
                dot.colorBlendFactor = 1
                dot.alpha = hunter || bot.racer ? 1 : 0.55
                mapContent.addChild(dot)
                botDots.append(dot)
            }
        }

        freeSpotPins.removeAll()
        if spotWars {
            for (k, free) in level.freeSpots.enumerated() {
                let pin = SKShapeNode(circleOfRadius: 4.5)
                pin.fillColor = UIColor(red: 1, green: 0.8, blue: 0.22, alpha: 1)
                pin.strokeColor = .white
                pin.lineWidth = 1.4
                pin.position = CGPoint(x: free.def.center.x * mapScale, y: free.def.center.y * mapScale)
                pin.zPosition = 3
                if traffic?.taken.contains(k) == true { pin.isHidden = true }
                mapContent.addChild(pin)
                freeSpotPins.append(pin)
            }
        }
        let spotSlots = spotWars ? [] : (friendPresent ? [otherSlot, slot] : [slot])
        for spotSlot in spotSlots {
            let def = level.spots[spotSlot]
            let color = CarArt.playerColors[spotSlot]
            let node: SKNode
            if isCity {
                // A destination pin: a ring with a bright centre
                let pin = SKShapeNode(circleOfRadius: spotSlot == slot ? 5.5 : 4)
                pin.fillColor = level.race ? UIColor(red: 1, green: 0.82, blue: 0.2, alpha: 1) : color
                pin.strokeColor = .white
                pin.lineWidth = 1.6
                node = pin
                node.position = CGPoint(x: def.center.x * mapScale, y: def.center.y * mapScale)
            } else {
                let bay = SKShapeNode(rectOf: CGSize(width: max(2, def.size.width * mapScale), height: max(2, def.size.height * mapScale)),
                                      cornerRadius: 1.5)
                bay.fillColor = color.withAlphaComponent(0.4)
                bay.strokeColor = color.lighter(by: 0.35)
                bay.lineWidth = 1.5
                bay.zRotation = def.angle
                node = bay
                node.position = CGPoint(x: def.center.x * mapScale, y: def.center.y * mapScale)
            }
            if spotSlot == slot {
                // A ripple spreading from the target
                let ripple = SKShapeNode(circleOfRadius: 6)
                ripple.strokeColor = (level.race ? UIColor(red: 1, green: 0.82, blue: 0.2, alpha: 1) : color).withAlphaComponent(0.9)
                ripple.lineWidth = 1.5
                ripple.fillColor = .clear
                ripple.position = node.position
                mapContent.addChild(ripple)
                ripple.run(.repeatForever(.sequence([
                    .group([.scale(to: 2.6, duration: 1.2), .fadeOut(withDuration: 1.2)]),
                    .run { ripple.setScale(1); ripple.alpha = 1 }])))
            }
            mapContent.addChild(node)
        }

        func marker(_ color: UIColor) -> SKShapeNode {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 7, y: 0))
            path.addLine(to: CGPoint(x: -5, y: 4.5))
            path.addLine(to: CGPoint(x: -3, y: 0))
            path.addLine(to: CGPoint(x: -5, y: -4.5))
            path.closeSubpath()
            let node = SKShapeNode(path: path)
            node.fillColor = color
            node.strokeColor = .white
            node.lineWidth = 1.2
            return node
        }
        friendMarker = marker(CarArt.playerColors[otherSlot])
        friendMarker.zPosition = 2
        mapContent.addChild(friendMarker)
        // The police car: a flashing dot
        policeMarker = SKShapeNode(circleOfRadius: 4.5)
        policeMarker.fillColor = UIColor(red: 1, green: 0.15, blue: 0.15, alpha: 1)
        policeMarker.strokeColor = .white
        policeMarker.lineWidth = 1.2
        policeMarker.zPosition = 3
        policeMarker.isHidden = true
        mapContent.addChild(policeMarker)

        // Vignette: the map fades into the rim
        let vignette = SKSpriteNode(texture: CarArt.minimapVignette)
        vignette.size = CGSize(width: radius * 2, height: radius * 2)
        minimap.addChild(vignette)
        // View cone ahead of the player (the map turns, the player always points up)
        let cone = SKSpriteNode(texture: CarArt.minimapCone)
        cone.size = CGSize(width: radius * 1.3, height: radius * 0.95)
        cone.anchorPoint = CGPoint(x: 0.5, y: 0)
        cone.color = CarArt.playerColors[slot].lighter(by: 0.3)
        cone.colorBlendFactor = 1
        cone.alpha = 0.5
        minimap.addChild(cone)
        // The player: a white navigation arrow with a coloured edge and a soft halo
        let halo = SKSpriteNode(texture: dotTexture)
        halo.size = CGSize(width: 28, height: 28)
        halo.color = CarArt.playerColors[slot]
        halo.colorBlendFactor = 1
        halo.alpha = 0.45
        minimap.addChild(halo)
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 9, y: 0))
        arrow.addLine(to: CGPoint(x: -7, y: 7))
        arrow.addLine(to: CGPoint(x: -3.5, y: 0))
        arrow.addLine(to: CGPoint(x: -7, y: -7))
        arrow.closeSubpath()
        myMarker = SKShapeNode(path: arrow)
        myMarker.fillColor = .white
        myMarker.strokeColor = CarArt.playerColors[slot]
        myMarker.lineWidth = 1.8
        myMarker.lineJoin = .round
        myMarker.zRotation = CGFloat.pi / 2
        minimap.addChild(myMarker)

        // Compass ring: ticks every 30 degrees and the four letters, north in red; it turns with
        // the map so N always points to world north
        mapCompass = SKNode()
        for k in 0..<12 {
            let angle = CGFloat(k) * .pi / 6
            let major = k % 3 == 0
            let tick = SKSpriteNode(color: UIColor.white.withAlphaComponent(major ? 0 : 0.35),
                                    size: CGSize(width: 1.2, height: 4))
            tick.position = CGPoint(x: cos(angle) * (radius + 1.5), y: sin(angle) * (radius + 1.5))
            tick.zRotation = angle - .pi / 2
            mapCompass.addChild(tick)
        }
        for (k, letter) in ["E", "N", "W", "S"].enumerated() {
            let angle = CGFloat(k) * .pi / 2
            let label = makeLabel(letter, size: letter == "N" ? 10 : 8,
                                  color: letter == "N" ? UIColor(red: 1, green: 0.35, blue: 0.35, alpha: 1) : UIColor.white.withAlphaComponent(0.6),
                                  font: "Barlow-ExtraBold")
            label.position = CGPoint(x: cos(angle) * (radius - 7), y: sin(angle) * (radius - 7))
            label.name = "letter"
            mapCompass.addChild(label)
        }
        minimap.addChild(mapCompass)
        northMarker = SKLabelNode()

        // Arrow on the rim pointing at the target when it is off the map
        targetPointer = makeIcon("arrowtriangle.up.fill", size: 11, color: level.race ? UIColor(red: 1, green: 0.82, blue: 0.2, alpha: 1)
                                                                                : CarArt.playerColors[slot].lighter(by: 0.3))
        minimap.addChild(targetPointer)

        // Distance to the target, in a pill on the bottom of the rim
        let pill = SKShapeNode(rectOf: CGSize(width: 46, height: 15), cornerRadius: 7.5)
        pill.fillColor = UIColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 0.95)
        pill.strokeColor = UIColor.white.withAlphaComponent(0.22)
        pill.lineWidth = 1
        pill.position = CGPoint(x: 0, y: -radius - 10)
        minimap.addChild(pill)
        mapDistance = makeLabel("", size: 9.5, color: .white, font: "Barlow-ExtraBold")
        mapDistance.verticalAlignmentMode = .center
        mapDistance.position = pill.position
        minimap.addChild(mapDistance)

        setNavShown(false)
        mapHeading = heading
        mapZoom = 1
        minimapTime = 0
        updateMinimap()
        // A new map fades and settles in
        mapContent.alpha = 0
        mapContent.run(.fadeIn(withDuration: 0.4))
        minimap.setScale(0.9)
        let settle = SKAction.scale(to: 1, duration: 0.45)
        settle.timingMode = .easeOut
        minimap.run(settle)
    }

    private func updateMinimap() {
        let dt = minimapTime > 0 ? min(0.1, max(0, lastUpdate - minimapTime)) : 0
        minimapTime = lastUpdate
        // Turn with the camera's direction (smoothed: a drift or a bump does not jerk the map),
        // and zoom out a little at speed
        let target = drifting ? travelHeading + CGFloat.angleDelta(travelHeading, heading) * 0.35 : heading
        if dt <= 0 {
            mapHeading = target
        } else {
            mapHeading += CGFloat.angleDelta(mapHeading, target) * (1 - exp(-CGFloat(dt) * 7))
        }
        let zoomTarget = 1 - 0.32 * min(1, abs(velocity) / max(1, maxForward))
        mapZoom += (zoomTarget - mapZoom) * (dt > 0 ? (1 - exp(-CGFloat(dt) * 2.2)) : 1)
        let rotation = CGFloat.pi / 2 - mapHeading
        mapContent.zRotation = rotation
        mapContent.setScale(mapZoom)
        mapCompass.zRotation = rotation
        // Keep the letters upright
        for child in mapCompass.children where child.name == "letter" { child.zRotation = -rotation }
        let car = CGPoint(x: carPosition.x * mapScale * mapZoom, y: carPosition.y * mapScale * mapZoom)
        mapContent.position = CGPoint(x: -(car.x * cos(rotation) - car.y * sin(rotation)),
                                      y: -(car.x * sin(rotation) + car.y * cos(rotation)))
        friendMarker.isHidden = !friendPresent
        friendMarker.position = CGPoint(x: remotePosition.x * mapScale, y: remotePosition.y * mapScale)
        friendMarker.zRotation = remoteHeading
        if let chase = police ?? remotePolice {
            policeMarker.isHidden = false
            policeMarker.position = CGPoint(x: chase.position.x * mapScale, y: chase.position.y * mapScale)
            let red = Int(lastUpdate * 6) % 2 == 0
            policeMarker.fillColor = red ? UIColor(red: 1, green: 0.15, blue: 0.15, alpha: 1) : UIColor(red: 0.2, green: 0.45, blue: 1, alpha: 1)
        } else {
            policeMarker.isHidden = true
        }
        if let bots = traffic?.bots {
            for (index, dot) in botDots.enumerated() where index < bots.count {
                dot.position = CGPoint(x: bots[index].position.x * mapScale, y: bots[index].position.y * mapScale)
                // A hunter that parked (or gave up) is ordinary traffic again on the map
                if (bots[index].hunt >= 0 || dot.alpha > 0.9) && !bots[index].racer && !bots[index].raceDone {
                    let hunting = bots[index].hazard
                    if (dot.alpha > 0.9) != hunting {
                        dot.alpha = hunting ? 1 : 0.55
                        if let sprite = dot as? SKSpriteNode {
                            sprite.color = hunting ? UIColor(red: 1, green: 0.66, blue: 0.12, alpha: 1) : UIColor(white: 0.92, alpha: 1)
                            sprite.size = hunting ? CGSize(width: 6.5, height: 6.5) : CGSize(width: 4.5, height: 4.5)
                        }
                    }
                }
            }
        }
        // The route starts at the car: the piece to the first turn follows it every frame
        if isCity && route.count >= 2 && !localParked {
            let lead = CGMutablePath()
            lead.move(to: CGPoint(x: carPosition.x * mapScale, y: carPosition.y * mapScale))
            lead.addLine(to: CGPoint(x: route[1].x * mapScale, y: route[1].y * mapScale))
            routeLead.path = lead
            routeLeadCasing.path = lead
        } else if isCity {
            routeLead.path = nil
            routeLeadCasing.path = nil
        }
        // Target pointer on the rim
        let goal = level.spots[slot].center
        let dx = (goal.x - carPosition.x) * mapScale * mapZoom
        let dy = (goal.y - carPosition.y) * mapScale * mapZoom
        let rx = dx * cos(rotation) - dy * sin(rotation)
        let ry = dx * sin(rotation) + dy * cos(rotation)
        let distance = hypot(rx, ry)
        if distance > mapRadius - 6 && !localParked {
            targetPointer.isHidden = false
            targetPointer.position = CGPoint(x: rx / distance * (mapRadius - 7), y: ry / distance * (mapRadius - 7))
            targetPointer.zRotation = atan2(ry, rx) - CGFloat.pi / 2
        } else {
            targetPointer.isHidden = true
        }
        // Distance (along the route in the city), a few times a second
        if lastUpdate - mapDistanceClock > 0.25 || mapDistanceClock == 0 {
            mapDistanceClock = lastUpdate
            var metres = carPosition.distance(to: goal) / 10
            if isCity && route.count >= 2 {
                metres = carPosition.distance(to: route[1]) / 10
                for k in 1..<(route.count - 1) { metres += route[k].distance(to: route[k + 1]) / 10 }
            }
            let text = localParked ? "✓" : (metres >= 1000 ? String(format: "%.1f km", metres / 1000) : "\(Int(metres.rounded())) m")
            if mapDistance.text != text { mapDistance.text = text }
        }
    }

    private func updateCarNodes() {
        guard let world = world else { return }
        let reversing = gear == .reverse && velocity < -1
        let (_, airPitch) = carLift()
        // The body rides on four springs; each wheel follows the ground under it
        localCar?.update(position: carPosition, heading: heading, steer: steer,
                         pitch: suspension.pitch + airPitch, roll: suspension.roll, braking: braking, reversing: reversing,
                         lift: Float(suspension.nodeLift), heave: Float(suspension.heave),
                         wheelLift: suspension.wheelLift.map { Float($0) })
        localTag.position = world.project(carPosition, height: 2.6)

        let showRemote = friendPresent
        remoteCar?.isHidden = !showRemote
        remoteTag.isHidden = !showRemote || spectateOverlay != nil
        remoteCar?.update(position: remotePosition, heading: remoteHeading, steer: remoteSteer,
                          braking: remoteBraking, reversing: remoteReversing)
        remoteTag.position = world.project(remotePosition, height: 2.6)
        remoteCheck.position = world.project(remotePosition, height: 4.0)
        if !showRemote { remoteCheck.isHidden = true }
        updateMinimap()
    }

    // MARK: Driving

    private func stepCar(_ dt: CGFloat) {
        let gasDown = isPressed(.forward)
        let reverseDown = isPressed(.reverse)
        let previousVelocity = velocity
        braking = false
        if gasDown || reverseDown { engaged = true }

        // Automatic gearbox: the opposite pedal brakes first, then selects the other gear
        if gasDown && reverseDown {
            braking = true
            velocity = approach(velocity, 0, brakeDecel * surface.brake * dt)
        } else if gasDown {
            if gear == .reverse && velocity < -2 {
                braking = true
                velocity = approach(velocity, 0, brakeDecel * surface.brake * dt)
            } else {
                gear = .drive
                let headroom = max(0, 1 - velocity / maxForward)
                // Engine pull follows the torque curve; it dips for a moment at each gear change
                let x = rpm / redline
                let torque = max(0.35, 1 - pow((x - 0.62) / 0.5, 2))
                let pull = (0.72 + 0.36 * torque) * (shiftCut > 0 ? 0.35 : 1)
                velocity += engineAccel * pow(headroom, 0.7) * pull * surface.traction * dt
            }
        } else if reverseDown {
            if gear == .drive && velocity > 2 {
                braking = true
                velocity = approach(velocity, 0, brakeDecel * surface.brake * dt)
            } else {
                gear = .reverse
                let headroom = max(0, 1 - (-velocity) / maxReverse)
                velocity -= reverseAccel * pow(headroom, 0.7) * surface.traction * dt
            }
        } else {
            let creep = engaged ? (gear == .drive ? creepSpeed : -creepSpeed) : 0
            if abs(velocity) < creepSpeed && engaged {
                velocity = approach(velocity, creep, 30 * dt)
            } else {
                // Rolling resistance, air drag and engine braking in gear
                let engineBrake = gear == .drive ? 16 * rpm / redline : 0
                let resistance = (rolling + engineBrake + airDrag * velocity * velocity * 0.01) * dt
                velocity = approach(velocity, creep, resistance)
            }
        }
        if isBoosting && gear == .drive {
            braking = false
            velocity += nitroPush * dt
        }
        let topSpeed = isBoosting ? maxForward * 1.7 : maxForward
        if velocity > topSpeed {
            velocity = isBoosting ? topSpeed : max(topSpeed, velocity - 110 * dt)
        }
        velocity = max(-maxReverse, velocity)
        runTopSpeed = max(runTopSpeed, Int(abs(velocity) * 0.36))

        let handbrake = isPressed(.handbrake)
        // Full lock while sliding, so the player can counter-steer
        let speedFactor = drifting ? 1 : 1 - 0.4 * min(1, abs(velocity) / maxForward)
        let targetSteer = wheelInput * maxSteer * speedFactor
        steer = approach(steer, targetSteer, steerRate * surface.steer * (drifting ? 1.6 : 1) * dt)

        // Drift: the body (heading) and the direction of travel (travelHeading) come apart.
        // Pulling the handbrake at speed locks the rear wheels and kicks the tail out toward the
        // steering; then the throttle keeps the rear wheels spinning (little rear grip, the angle
        // holds), counter-steer balances it, and lifting off gives the grip back. Steering into
        // the slide on throttle spins the car; the car's yaw has inertia, so the angle builds and
        // settles instead of jumping.
        if !drifting { travelHeading = heading }
        // Into a drift: the DRIFT button at speed, or a dab of the brake while steering hard
        let brakeFlick = reverseDown && !gasDown && velocity > 55 && abs(wheelInput) > 0.6
        if (handbrake || brakeFlick) && velocity > 35 && !drifting && airTime <= 0 { startDrift() }
        var steerYaw = velocity / wheelBase * tan(steer)
        // The tyres can only hold so much sideways force: past it the car runs wide (understeer)
        // and the tyres squeal
        // Wet or snowy: less side grip, and on water at speed the tyres start to float (aquaplaning)
        let floating = isRaining ? max(0, abs(velocity) / maxForward - 0.7) * 1.2 : 0
        // Weight transfer: braking loads the front tyres (sharper turn-in), the throttle unloads
        // them (the nose pushes wide), and a car leaning hard in a corner loses a little grip
        let frontShare = max(0.6, min(1.4, suspension.frontLoad / 0.5))
        let loadGrip = (0.55 + 0.45 * pow(frontShare, 0.85)) * (1 - 0.15 * suspension.lateralTransfer)
        let maxLateral = lateralGrip * surface.grip * (1 - min(0.35, floating)) * loadGrip
        understeer = 0
        let demand = velocity * steerYaw          // the sideways pull the steering asks for
        gripUse = abs(demand) / max(maxLateral, 1)
        if !drifting && abs(demand) > maxLateral {
            understeer = min(1, (abs(demand) - maxLateral) / 300)
            steerYaw = (steerYaw > 0 ? 1 : -1) * maxLateral / max(abs(velocity), 1)
        }
        // Slippery road: past the grip the tail steps out and the car slides on its line, more
        // the faster it goes and the harder it is steered (snow far more than rain); even
        // straight on, a fast car on snow wanders a little. Easing off lets the tyres bite again.
        // A light rear (hard braking, lifting off mid-corner) lets the tail step out a little even
        // on a dry road
        let rearShare = 2 - frontShare
        let lightRear = max(0, 0.86 - rearShare)
        let slippery: CGFloat = (isSnowing ? 1 : (isRaining ? 0.6 : 0)) + lightRear * 1.4
        var line = heading - skid
        if drifting || airTime > 0 || slippery == 0 || velocity < 0 {
            skid += (0 - skid) * min(1, dt * 6)
            line = heading - skid
        } else {
            let fast = max(0, min(1, (abs(velocity) / maxForward - 0.3) / 0.6))
            let excess = max(0, abs(demand) / max(maxLateral, 1) - 0.55)
            var target = (demand >= 0 ? 1 : -1) * min(0.55, excess * 0.32) * slippery * fast * (1 + lightRear * 2)
            target += sin(CGFloat(elapsed) * 1.7) * 0.035 * slippery * fast * fast
            if gasDown && fast > 0.4 { target *= 1.25 }                      // power oversteer
            let rate: CGFloat = abs(target) > abs(skid) ? 2.6 : 1.4 + 2.2 * surface.grip
            skid += (target - skid) * min(1, dt * rate)
            // Sliding scrubs speed and squeals
            velocity -= velocity * abs(skid) * 0.22 * dt
            understeer = max(understeer, min(1, abs(skid) * 2.2))
        }
        line += steerYaw * dt
        var newHeading = line + skid
        if drifting && airTime <= 0 {
            // Arcade drift: the car slides at a held angle to its line and carves the corner
            // faster than grip allows, keeping almost all its speed. Steering into the drift
            // tightens it and opens the angle, steering out straightens it; letting go of both the
            // button and the steering eases the car straight and the drift ends. No spin-outs.
            let input = wheelInput * driftSide           // > 0: into the drift, < 0: counter-steer
            let into = max(0, input), against = max(0, -input)
            driftCounter = against > 0.3 ? driftCounter + dt : 0
            if !driftExiting && ((!handbrake && abs(wheelInput) < 0.1) || driftCounter > 0.22 || velocity < 28) {
                driftExiting = true
            }
            let grip = surface.grip
            let targetSlip: CGFloat = driftExiting ? 0 : driftSide * (0.32 + 0.26 * into - 0.18 * against) * (0.85 + 0.15 * grip)
            driftSlip += (targetSlip - driftSlip) * min(1, dt * (driftExiting ? 7 : 4.5))
            // How fast the line turns: tighter than grip at speed, more with the steering held in
            let speedShare = min(1, abs(velocity) / 90)
            let turn = driftExiting ? 0 : driftSide * (0.55 + 0.75 * into - 0.45 * against) * (1.1 + 0.6 * speedShare) * (0.7 + 0.3 * grip)
            travelHeading += turn * dt
            newHeading = travelHeading + driftSlip
            yawSpeed = (newHeading - heading) / max(dt, 0.0001)
            // A light scrub only (Asphalt keeps the speed through a drift); the throttle holds it
            velocity -= velocity * (0.07 + 0.08 * abs(sin(driftSlip))) * dt
            // Nitro fills while sliding
            if !driftExiting { nitro = min(1, nitro + dt * 0.09 * min(1, abs(driftSlip) / 0.35) * speedShare) }
            let before = driftClock
            driftClock += dt
            driftScore += abs(velocity) * abs(driftSlip) * dt * 0.9
            if before < 2.2 && driftClock >= 2.2 { dispatchPolice(Strings.crimeDrift) }
            if driftExiting && abs(driftSlip) < 0.03 {
                newHeading = travelHeading
                endDrift()
            }
        } else {
            yawSpeed = airTime > 0 ? 0 : steerYaw
        }
        if airTime > 0 { newHeading = heading }   // no steering in the air
        let yawRate = (newHeading - heading) / max(dt, 0.0001)
        let moveHeading = drifting ? travelHeading : newHeading - skid
        let newPosition = CGPoint(x: carPosition.x + cos(moveHeading) * velocity * dt,
                                  y: carPosition.y + sin(moveHeading) * velocity * dt)

        if let last = yawRateHeading, dt > 0 {
            let raw = max(-4, min(4, CGFloat.angleDelta(last, heading) / dt))
            sentYawRate += (raw - sentYawRate) * min(1, dt * 15)
        }
        yawRateHeading = heading
        let longitudinal = (velocity - previousVelocity) / max(dt, 0.001)
        longitudinalAccel += (longitudinal - longitudinalAccel) * min(1, dt * 8)
        lateralAccel += (velocity * yawRate - lateralAccel) * min(1, dt * 8)

        // Hitting another car is handled first, from the speed at which the two cars close in
        // (head-on, glancing or from behind alike), so every real car crash reacts the same way
        if let impact = carImpact(OBB(center: newPosition, size: Levels.carSize, angle: newHeading), to: newPosition) {
            // A real crash (not just leaning on a stopped car); the same rule for every car
            var friendJustHitUs = false
            if case .remoteCar = impact.contact { friendJustHitUs = lastUpdate - hitByFriendAt < 0.5 }
            if impact.closing > 22 && lastUpdate - lastHitAt > 0.45 && !friendJustHitUs && freshHit() {
                countHit()
                crashCar(impact)
            } else {
                // Leaning on a car (or still touching after a crash): we do not drive into it
                velocity *= 0.3
            }
            applyCrashMotion(dt)
            gearLabel.text = gear == .drive ? "\(gearIndex)" : "R"
            tyreEffects(dt, accelerating: gasDown || reverseDown)
            return
        }

        // Walls, kerbs and parked cars, as in Asphalt: a glancing hit guides the car along the
        // wall (it turns with it, keeps most of its speed and the steering still works, so the
        // player can pull away); only a near head-on hit stops it.
        var slid = false
        var lostSpeed = abs(velocity)
        if blocked(moving: OBB(center: newPosition, size: Levels.carSize, angle: newHeading), to: newPosition),
           let normal = wallNormal(), abs(velocity) > 3 {
            let sign: CGFloat = velocity >= 0 ? 1 : -1
            let dir = CGVector(dx: cos(moveHeading) * sign, dy: sin(moveHeading) * sign)
            let dot = dir.dx * normal.dx + dir.dy * normal.dy
            let into = max(0, -dot)                         // 0: along the wall, 1: straight at it
            if into < 0.92 {
                var tangent = CGVector(dx: dir.dx - normal.dx * dot, dy: dir.dy - normal.dy * dot)
                let length = max(0.001, hypot(tangent.dx, tangent.dy))
                tangent = CGVector(dx: tangent.dx / length, dy: tangent.dy / length)
                // The nose swings round to run along the wall; the player's steering adds to it
                let along = atan2(tangent.dy, tangent.dx) + (sign < 0 ? .pi : 0)
                let turned = newHeading + CGFloat.angleDelta(newHeading, along) * min(1, dt * 5) * into
                let step = abs(velocity) * dt
                let options = [CGPoint(x: carPosition.x + tangent.dx * step + normal.dx * 0.4, y: carPosition.y + tangent.dy * step + normal.dy * 0.4),
                               CGPoint(x: carPosition.x + normal.dx * 0.8, y: carPosition.y + normal.dy * 0.8)]
                for (k, candidate) in options.enumerated() {
                    for h in [turned, heading] {
                        if !blocked(moving: OBB(center: candidate, size: Levels.carSize, angle: h), to: candidate) {
                            carPosition = candidate
                            heading = h
                            if drifting { travelHeading = h - driftSlip }
                            slid = true
                            lostSpeed = abs(velocity) * into
                            if k == 1 { velocity *= 0.85 }
                            break
                        }
                    }
                    if slid { break }
                }
                // Speed lost to the wall: little when brushing it, more the steeper the hit
                if slid { velocity -= velocity * min(0.6, into * 1.4) * min(1, dt * 8) }
            }
        }
        if !slid && blocked(moving: OBB(center: newPosition, size: Levels.carSize, angle: newHeading), to: newPosition) {
            // Unknown wall shape: keep the free axis instead of stopping dead
            let candidates = [(CGPoint(x: newPosition.x, y: carPosition.y), abs(sin(heading) * velocity)),
                              (CGPoint(x: carPosition.x, y: newPosition.y), abs(cos(heading) * velocity))]
            for (candidate, lost) in candidates.sorted(by: { $0.1 < $1.1 }) where candidate.distance(to: carPosition) > 0.05 {
                for h in [newHeading, heading] where !blocked(moving: OBB(center: candidate, size: Levels.carSize, angle: h), to: candidate) {
                    carPosition = candidate
                    heading = h
                    lostSpeed = lost
                    slid = true
                    velocity *= 0.94
                    break
                }
                if slid { break }
            }
        }
        if slid {
            if lostSpeed > 45 && lastUpdate - lastHitAt > 0.6 && freshHit() {
                countHit()
                bumpHaptic.impactOccurred(intensity: 0.5)
                audio.play("bump", volume: 0.5)
                rockHitCars(OBB(center: newPosition, size: Levels.carSize, angle: newHeading), speed: lostSpeed)
            } else if lostSpeed > 8 {
                tickHaptic.impactOccurred(intensity: 0.25)
            }
        } else if blocked(moving: OBB(center: newPosition, size: Levels.carSize, angle: newHeading), to: newPosition) {
            let impact = abs(velocity)
            var crashed = false
            if lastUpdate - lastHitAt > 0.6 && impact > 18 && freshHit() {
                countHit()
                bumpHaptic.impactOccurred(intensity: min(1, impact / 120 + 0.4))
                rockHitCars(OBB(center: newPosition, size: Levels.carSize, angle: newHeading), speed: impact)
                let direction: CGFloat = velocity >= 0 ? 1 : -1
                dust(at: CGPoint(x: carPosition.x + cos(heading) * 22 * direction,
                                 y: carPosition.y + sin(heading) * 22 * direction))
                crashed = crash(into: OBB(center: newPosition, size: Levels.carSize, angle: newHeading), impact: impact)
                if impact > 40 { failDrift() }
                if !crashed {
                    audio.play("bump", volume: Float(min(1, impact / 100 + 0.3)))
                    world?.shake(strength: min(6, impact / 20))
                }
            }
            // Asphalt: with the throttle held and the wheel turned, the car swings its nose off the
            // wall and drives away instead of bouncing against it
            if !crashed && (gasDown || reverseDown) && abs(wheelInput) > 0.15 && pivotOffWall(dt, reverse: reverseDown && !gasDown) {
                velocity = (gasDown ? 1 : -1) * min(abs(velocity), 30)
            } else if impact <= 18 {
                // Leaning on it at walking pace: the car just stands against it (it used to bounce
                // back and forth every few frames, the body rocking with each bounce)
                velocity = 0
                longitudinalAccel *= 0.5
            } else {
                velocity = abs(velocity) < 6 ? 0 : -velocity * (crashed ? 0.12 : 0.22)
                longitudinalAccel = -longitudinalAccel
            }
        } else {
            carPosition = newPosition
            heading = newHeading
        }

        knockCones()
        applyCrashMotion(dt)
        updateSuspension(dt)
        updateJump(dt)
        updateDriftDisplay(dt)

        gearLabel.text = gear == .drive ? "\(gearIndex)" : "R"
        gearLabel.fontColor = gear == .drive ? UIColor(red: 0.45, green: 0.95, blue: 0.6, alpha: 1)
                                             : UIColor(red: 1.0, green: 0.55, blue: 0.45, alpha: 1)
        tyreEffects(dt, accelerating: gasDown || reverseDown)
    }

    /// Picks the gear from the speed (up near the top of each gear, down well below it) and
    /// eases the rpm toward that gear's revs: quick to rise, quicker to drop on a shift.
    private func updateGearbox(_ dt: CGFloat, throttle: Bool) {
        let speed = abs(velocity)
        shiftCut = max(0, shiftCut - dt)
        var target: CGFloat
        if gear == .reverse && velocity < -1 {
            target = idleRPM + (redline * 0.75 - idleRPM) * min(1, speed / maxReverse)
        } else {
            let ratio = speed / (gearTops[gearIndex - 1] * maxForward)
            if ratio > 0.95 && gearIndex < gearTops.count && (throttle || isBoosting) && phase == .driving {
                gearIndex += 1
                shiftCut = 0.16
                audio.play("shift", volume: 0.22)
                tickHaptic.impactOccurred(intensity: 0.3)
            } else if gearIndex > 1 && speed < gearTops[gearIndex - 2] * maxForward * 0.62 {
                gearIndex -= 1
            }
            target = idleRPM + (redline - idleRPM) * min(1.02, speed / (gearTops[gearIndex - 1] * maxForward))
        }
        // Revving on the spot, and wheelspin in a drift
        if throttle && speed < 15 { target = max(target, phase == .countdown ? 5400 : 2800) }
        if throttle && drifting { target = max(target, redline * 0.86) }
        let rate: CGFloat = target > rpm ? 9 : (shiftCut > 0 ? 22 : 5)
        rpm += (target - rpm) * min(1, rate * dt)
        lastThrottle = throttle
        if gear == .drive, gearLabel.text != "\(gearIndex)", phase == .driving { gearLabel.text = "\(gearIndex)" }
    }

    private func approach(_ value: CGFloat, _ target: CGFloat, _ step: CGFloat) -> CGFloat {
        if value < target { return min(value + step, target) }
        return max(value - step, target)
    }

    // MARK: Drift, jumps, near misses, props and police

    private func startDrift() {
        drifting = true
        driftExiting = false
        driftCounter = 0
        driftScore = 0
        driftClock = 0
        driftCalm = 0
        travelHeading = heading
        driftSlip = 0
        // The drift goes the way the player steers (or the way the car is already turning)
        driftSide = wheelInput > 0.1 ? 1 : (wheelInput < -0.1 ? -1 : (steer >= 0 ? 1 : -1))
        tickHaptic.impactOccurred(intensity: 0.7)
    }

    /// A finished drift: its points become nitro.
    private func endDrift() {
        guard drifting else { return }
        drifting = false
        driftExiting = false
        driftSlip = 0
        lastDriftEnd = lastUpdate
        lastDriftScore = driftScore
        travelHeading = heading
        let points = Int(driftScore.rounded())
        if driftScore > 40 && driftClock > 0.4 {
            runDriftPoints += points
            nitro = min(1, nitro + min(0.25, driftScore / 3000))
            flashBonus(Strings.driftBonus(points))
            audio.play("whoosh", volume: 0.5)
            notifyHaptic.notificationOccurred(.success)
        }
        driftScore = 0
    }

    /// A crash during a drift loses its points.
    private func failDrift() {
        guard drifting else { return }
        drifting = false
        driftExiting = false
        driftSlip = 0
        lastDriftEnd = -10
        lastDriftScore = 0
        travelHeading = heading
        if driftScore > 40 { flashBonus(Strings.driftLost) }
        driftScore = 0
    }

    private func updateDriftDisplay(_ dt: CGFloat) {
        if drifting && driftScore > 5 {
            let points = Int(driftScore.rounded())
            if points != shownDriftPoints {
                shownDriftPoints = points
                driftLabel.text = "\(Strings.driftLabel) \(points)"
            }
            if driftLabel.alpha < 1 {
                driftLabel.removeAllActions()
                driftLabel.alpha = 1
                driftLabel.setScale(0.7)
                driftLabel.run(.scale(to: 1, duration: 0.15))
            }
            // Thick tyre smoke from the rear wheels
            driftSmokeClock += dt
            if driftSmokeClock > 0.07 {
                driftSmokeClock = 0
                for side: CGFloat in [11, -11] {
                    let point = CGPoint(x: carPosition.x - 14 * cos(heading) - side * sin(heading),
                                        y: carPosition.y - 14 * sin(heading) + side * cos(heading))
                    tyreSmoke(at: point)
                }
            }
        } else if driftLabel.alpha > 0.01 && driftLabel.action(forKey: "out") == nil {
            shownDriftPoints = -1
            driftLabel.run(.sequence([.fadeAlpha(to: 0.002, duration: 0.25)]), withKey: "out")
        }
    }

    private func tyreSmoke(at point: CGPoint) {
        guard let screen = world?.project(point, height: 0.3) else { return }
        let puff = SKSpriteNode(texture: dotTexture)
        puff.size = CGSize(width: 16, height: 16)
        puff.color = UIColor(white: 0.92, alpha: 1)
        puff.colorBlendFactor = 1
        puff.position = screen
        puff.alpha = 0.42
        fxLayer.addChild(puff)
        puff.run(.sequence([
            .group([.scale(to: 4.0, duration: 0.9), .fadeOut(withDuration: 0.9),
                    .moveBy(x: CGFloat.random(in: -14...14), y: CGFloat.random(in: 4...20), duration: 0.9)]),
            .removeFromParent()
        ]))
    }

    /// Height of a ramp under a point (meters), and the distance along the ramp.
    private func rampHeight(at p: CGPoint) -> CGFloat {
        for ramp in level.ramps {
            let along = ramp.alongX ? p.x - ramp.center.x : p.y - ramp.center.y
            let across = ramp.alongX ? p.y - ramp.center.y : p.x - ramp.center.x
            let half = RampDef.length / 2
            let top = half * 0.25
            guard abs(across) < RampDef.width / 2, abs(along) < half else { continue }
            if abs(along) < top { return RampDef.height }
            return RampDef.height * (half - abs(along)) / (half - top)
        }
        return 0
    }

    /// Takes off from the top of a ramp at speed; lands with a thump and a nitro bonus.
    private func updateJump(_ dt: CGFloat) {
        if airTime > 0 {
            airTime -= dt
            if airTime <= 0 {
                airTime = 0
                bumpHaptic.impactOccurred(intensity: 1.0)
                audio.play("bump", volume: 0.8)
                world?.shake(strength: 4)
                dust(at: carPosition)
                nitro = min(1, nitro + 0.2)
                flashBonus(Strings.jump)
            }
            return
        }
        guard rampHeight(at: carPosition) >= RampDef.height - 0.01, abs(velocity) > 50, lastUpdate - rampCooldown > 1.2 else { return }
        rampCooldown = lastUpdate
        airDuration = 0.35 + abs(velocity) / 320
        airPeak = min(3.2, abs(velocity) * 0.014)
        airTime = airDuration
        if drifting { endDrift() }
        tickHaptic.impactOccurred(intensity: 1.0)
    }

    /// The car's height above the ground (on a ramp or in the air) and its pitch in the air.
    /// Four-corner suspension: each wheel finds the ground under it (road, raised pavement,
    /// ramp), and the body rides on a spring and damper at every corner with an anti-roll bar.
    /// Braking and accelerating pitch it, cornering rolls it, kerbs and landings compress it and
    /// it settles with a bounce; the load on each axle feeds back into the grip.
    private func updateSuspension(_ dt: CGFloat) {
        guard dt > 0 else { return }
        let c = cos(heading), s = sin(heading)
        let city = level.city
        func ground(_ along: CGFloat, _ across: CGFloat) -> CGFloat {
            let p = CGPoint(x: carPosition.x + c * along - s * across, y: carPosition.y + s * along + c * across)
            return (city?.kerbHeight(at: p) ?? 0) + rampHeight(at: p) - rampHeight(at: carPosition)
        }
        let (lift, _) = carLift()
        let airborne = airTime > 0
        let grounds: [CGFloat] = airborne
            ? [-0.07, -0.07, -0.07, -0.07]          // wheels hang on their springs in the air
            : [ground(13.5, 8.2), ground(13.5, -8.2), ground(-13.5, 8.2), ground(-13.5, -8.2)]
        // Inputs in metres per second squared, kept to what a real car reaches
        let ax = max(-13, min(13, longitudinalAccel / 10))
        let ay = max(-13, min(13, lateralAccel / 10))
        suspension.step(dt, nodeLift: CGFloat(lift), grounds: grounds, ax: airborne ? 0 : ax, ay: airborne ? 0 : ay)

        // Kerbs: a thud and a little speed lost as each axle climbs, a drop as it comes down
        guard let city = city else { return }
        func kerb(_ along: CGFloat) -> CGFloat {
            (city.kerbHeight(at: CGPoint(x: carPosition.x + c * along - s * 8.2, y: carPosition.y + s * along + c * 8.2))
             + city.kerbHeight(at: CGPoint(x: carPosition.x + c * along + s * 8.2, y: carPosition.y + s * along - c * 8.2))) / 2
        }
        let front = kerb(13.5), rear = kerb(-13.5)
        let top = CityMap.kerbTop
        let speed = abs(velocity)
        func hit(_ before: CGFloat, _ now: CGFloat, strength: CGFloat) {
            let climbed = before < top * 0.45 && now >= top * 0.45
            let dropped = before > top * 0.55 && now <= top * 0.55
            guard (climbed || dropped) && speed > 6 else { return }
            let force = min(1, speed / 120)
            if climbed {
                velocity *= 1 - (0.05 + 0.13 * force) * strength
                bumpHaptic.impactOccurred(intensity: 0.35 + 0.5 * force * strength)
                audio.play("bump", volume: Float(0.18 + 0.3 * force * strength))
                if force > 0.4 { world?.shake(strength: 0.6 + 1.6 * force * strength) }
            } else {
                tickHaptic.impactOccurred(intensity: 0.3 + 0.4 * force)
            }
        }
        let leading = velocity >= 0 ? front : rear, trailing = velocity >= 0 ? rear : front
        hit(frontKerb, leading, strength: 1)
        hit(rearKerb, trailing, strength: 0.7)
        frontKerb = leading
        rearKerb = trailing
    }

    private func carLift() -> (Float, CGFloat) {
        if airTime > 0, airDuration > 0 {
            let t = 1 - airTime / airDuration
            let height = RampDef.height * (1 - t) + 4 * airPeak * t * (1 - t)
            return (Float(height), 0.12 * (1 - 2 * t))
        }
        return (Float(rampHeight(at: carPosition)), 0)
    }

    /// Near misses, flying props, the police chase and the trail it follows.
    private func updateArcade(_ dt: CGFloat, traffic: Traffic) {
        let driving = phase == .driving && !localParked
        let moveHeading = drifting ? travelHeading : heading
        // Near miss: passing a car side by side with less than about a meter between them
        if driving && abs(velocity) > 70 && airTime <= 0 {
            for (index, bot) in traffic.bots.enumerated() {
                let dx = bot.position.x - carPosition.x, dy = bot.position.y - carPosition.y
                if abs(dx) > 60 || abs(dy) > 60 { continue }
                let along = dx * cos(heading) + dy * sin(heading)
                let across = -dx * sin(heading) + dy * cos(heading)
                guard abs(along) < 20, abs(across) > 23, abs(across) < 34 else { continue }
                guard lastUpdate - (nearMissAt[index] ?? -10) > 3, lastUpdate - lastHitAt > 1 else { continue }
                nearMissAt[index] = lastUpdate
                nitro = min(1, nitro + 0.12)
                flashBonus(Strings.nearMiss)
                runNearMisses += 1
                audio.play("whoosh", volume: 0.8)
                tickHaptic.impactOccurred(intensity: 0.8)
            }
        }
        // Props: our car, the traffic and the police knock them over
        if let props = streetProps {
            var hitters: [(position: CGPoint, velocity: CGVector, heading: CGFloat)] = [
                (carPosition, airTime > 0 ? .zero : CGVector(dx: cos(moveHeading) * velocity, dy: sin(moveHeading) * velocity), heading)
            ]
            for bot in traffic.bots where abs(bot.position.x - carPosition.x) < 800 && abs(bot.position.y - carPosition.y) < 800 {
                hitters.append((bot.position, CGVector(dx: cos(bot.heading) * bot.speed, dy: sin(bot.heading) * bot.speed), bot.heading))
            }
            if props.step(dt, hitters: hitters) > 0 {
                velocity *= 0.92
                audio.play("bump", volume: 0.4)
                tickHaptic.impactOccurred(intensity: 0.6)
            }
        }
        // Traffic lights: a car that runs into one knocks it over (it pivots on its foot and falls
        // the way the car was going); the car loses some speed but drives on
        if let world = world, airTime <= 0 {
            let carBox = OBB(center: carPosition, size: CGSize(width: Levels.carSize.width + 6, height: Levels.carSize.height + 6), angle: heading)
            for pole in world.signalPoles where !pole.fallen {
                if abs(pole.position.x - carPosition.x) > 40 || abs(pole.position.y - carPosition.y) > 40 { continue }
                guard carBox.contains(pole.position), abs(velocity) > 12 else { continue }
                let direction = CGVector(dx: cos(moveHeading) * (velocity >= 0 ? 1 : -1), dy: sin(moveHeading) * (velocity >= 0 ? 1 : -1))
                world.knockSignal(pole, direction: direction, speed: abs(velocity))
                velocity *= 0.72
                audio.play("crash", volume: 0.45)
                bumpHaptic.impactOccurred(intensity: 0.8)
                world.shake(strength: 2)
            }
            world.stepFallingSignals(Float(dt))
        }
        // The trail the police follows
        trailClock += dt
        if trailClock > 0.1 && driving {
            trailClock = 0
            trail.append(carPosition)
            if trail.count > 140 { trail.removeFirst(trail.count - 140) }
        }
        // The friend's police car (online): shown where the friend's game says it is
        var siren: CGFloat = 0
        if let target = remotePoliceTarget, friendPresent, !remoteParked, let world = world, let city = level.city {
            if remotePolice == nil {
                remotePolice = PoliceChase(node: world.makePoliceNode(), map: city, start: target.position)
            }
            remotePolice?.mirror(dt, to: target.position, heading: target.heading, viewer: carPosition)
            if let other = remotePolice { siren = max(siren, 0.6 - other.distance / 1600) }
        } else if remotePolice != nil {
            removeRemotePolice()
        }
        if let chase = police, driving {
            let moving = drifting ? travelHeading : heading
            let outcome = chase.step(dt, player: carPosition, playerSpeed: abs(velocity),
                                     playerVelocity: CGVector(dx: cos(moving) * velocity, dy: sin(moving) * velocity), trail: trail)
            chase.keepClear(of: carPosition, heading: heading)
            // The siren gets louder as the police closes in
            siren = max(siren, max(0.12, min(0.8, 0.85 - chase.distance / 1600)))
            if chase.mode == .chasing { updatePoliceWarning(chase) }
            if busted { siren = 0.9; updateBusted(dt, chase) }
            if chase.mode == .leaving {
                siren = max(0, 0.5 - chase.distance / 900)
                if chase.finished { endPoliceChase() }
            }
            switch outcome {
            case .caught:
                startBusted(chase)
                if taxiState == .riding { loseTip(Strings.riderCaught) }
            case .escaped:
                runEscapes += 1
                if taxiState == .riding && level.taxi?.rider == .getaway { taxiEscaped = true }
                nitro = 1
                flashBonus(Strings.policeEscaped)
                notifyHaptic.notificationOccurred(.success)
                endPoliceChase()
            case .none:
                break
            }
        } else if police != nil {
            endPoliceChase()
        }
        audio.setLoop("siren", volume: phase == .driving && !localParked ? Float(max(0, siren)) : 0)
    }

    private func removeRemotePolice() {
        guard let other = remotePolice else { return }
        remotePolice = nil
        other.node.runAction(.sequence([.fadeOut(duration: 0.5), .removeFromParentNode()]))
    }

    /// A crime (crash, hitting a pedestrian, a long drift, speeding past a radar) calls the police:
    /// a cruiser sets off from an intersection some way off and drives the streets to us with its
    /// siren on, then chases us. Another crime during a chase keeps it going longer.
    private func dispatchPolice(_ reason: String) {
        guard let city = level.city, let world = world, phase == .driving, !localParked else { return }
        if let chase = police {
            chase.extend()
            showPoliceWarning(reason)
            return
        }
        guard lastUpdate >= policeCooldownUntil else { return }
        // An intersection 45–90 m away, preferably behind us
        var best: CGPoint?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for x in city.xs {
            for y in city.ys {
                let point = CGPoint(x: x, y: y)
                let d = point.distance(to: carPosition)
                let ahead = ((x - carPosition.x) * cos(heading) + (y - carPosition.y) * sin(heading)) / max(d, 1)
                let score = abs(d - 650) + (d < 380 ? 2000 : 0) + max(0, ahead) * 400
                if score < bestScore {
                    bestScore = score
                    best = point
                }
            }
        }
        guard let start = best else { return }
        var clock = CACurrentMediaTime()
        func lap(_ name: String) {
            guard benchmark else { return }
            let now = CACurrentMediaTime()
            FileHandle.standardError.write(String(format: "PPTIME %@ %.2f ms\n", name, (now - clock) * 1000).data(using: .utf8)!)
            clock = now
        }
        let node = world.makePoliceNode()
        lap("police-node")
        police = PoliceChase(node: node, map: city, start: start)
        if let police { LeakWatch.track(police, "PoliceChase") }
        lap("police-chase")
        showPoliceWarning(reason)
        lap("police-banner")
        notifyHaptic.notificationOccurred(.warning)
        lap("police-haptic")
    }

    // MARK: Busted

    /// Caught by the police: the cruiser boxes the car in, the camera circles it, and after a few
    /// seconds (the time lost is part of the penalty, with two crashes on the count) it lets go.
    private var busted = false
    private var bustedClock: CGFloat = 0
    private let bustedDuration: CGFloat = 3.4
    private var bustedNode: SKNode?
    private var bustedBar = SKSpriteNode()

    private func startBusted(_ chase: PoliceChase) {
        busted = true
        bustedClock = 0
        hits += 2
        hitsLabel.text = "\(hits)"
        failDrift()
        boostTime = 0
        chase.pullOver(player: carPosition, heading: heading)
        notifyHaptic.notificationOccurred(.error)
        bumpHaptic.impactOccurred(intensity: 0.7)
        audio.play("horn", volume: 0.5)
        hidePoliceWarning()
        world?.resetSpectate()

        bustedNode?.removeFromParent()
        let node = SKNode()
        node.position = CGPoint(x: size.width / 2 + 40, y: size.height * 0.64)
        node.zPosition = 30
        let width: CGFloat = 330
        let back = SKShapeNode(rect: CGRect(x: -width / 2, y: -38, width: width, height: 76), cornerRadius: 18)
        back.fillColor = UIColor(red: 0.08, green: 0.02, blue: 0.05, alpha: 0.88)
        back.strokeColor = UIColor(red: 1, green: 0.22, blue: 0.22, alpha: 1)
        back.lineWidth = 3
        back.name = "back"
        node.addChild(back)
        let title = makeLabel(Strings.bustedTitle, size: 30, color: .white, font: "Barlow-ExtraBold")
        title.position = CGPoint(x: 0, y: 8)
        node.addChild(title)
        let detail = makeLabel(Strings.bustedPenalty, size: 12, color: UIColor(white: 1, alpha: 0.85))
        detail.position = CGPoint(x: 0, y: -16)
        node.addChild(detail)
        // The time left until the police lets go, as a bar along the bottom
        bustedBar = SKSpriteNode(color: UIColor(red: 1, green: 0.3, blue: 0.3, alpha: 1), size: CGSize(width: width - 36, height: 4))
        bustedBar.anchorPoint = CGPoint(x: 0, y: 0.5)
        bustedBar.position = CGPoint(x: -(width - 36) / 2, y: -30)
        node.addChild(bustedBar)
        node.setScale(0.6)
        node.alpha = 0
        node.run(.group([.fadeIn(withDuration: 0.15), .sequence([.scale(to: 1.08, duration: 0.15), .scale(to: 1.0, duration: 0.1)])]))
        hud.addChild(node)
        bustedNode = node
        if benchmark { run(.wait(forDuration: 1.2)) { Task { @MainActor in saveWindowSnapshot(named: "shot-busted") } } }
    }

    private func updateBusted(_ dt: CGFloat, _ chase: PoliceChase) {
        bustedClock += dt
        // The car rolls to a stop
        velocity *= exp(-dt * 4)
        bustedBar.xScale = max(0, 1 - bustedClock / bustedDuration)
        // Red and blue fill the screen edges, in time with the light bar
        let flash = Int(lastUpdate * 6) % 2 == 0
        if policeEdges.count == 2 {
            policeEdges[0].alpha = flash ? 0.85 : 0.15
            policeEdges[1].alpha = flash ? 0.15 : 0.85
        }
        if let back = bustedNode?.childNode(withName: "back") as? SKShapeNode {
            back.strokeColor = flash ? UIColor(red: 1, green: 0.22, blue: 0.22, alpha: 1) : UIColor(red: 0.25, green: 0.5, blue: 1, alpha: 1)
        }
        guard bustedClock >= bustedDuration else { return }
        // Let go: the cruiser drives off, the camera comes back behind the car
        busted = false
        chase.driveOff(from: carPosition)
        world?.endSpectate()
        // Straight back behind the car (easing from the orbit could pass through a building)
        world?.follow(position: carPosition, heading: heading, dt: 0, snap: true)
        policeEdges.forEach { $0.run(.fadeAlpha(to: 0.002, duration: 0.3)) }
        bustedNode?.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        bustedNode = nil
        flashBonus(Strings.bustedReleased)
        notifyHaptic.notificationOccurred(.success)
    }

    private func endPoliceChase() {
        guard let chase = police else { return }
        if busted {
            busted = false
            world?.endSpectate()
            bustedNode?.removeFromParent()
            bustedNode = nil
        }
        police = nil
        policeCooldownUntil = lastUpdate + 10
        audio.setLoop("siren", volume: 0)
        hidePoliceWarning()
        chase.node.runAction(.sequence([.wait(duration: 1.5), .fadeOut(duration: 0.6), .removeFromParentNode()]))
    }

    // MARK: Police warning

    private var policeCooldownUntil: TimeInterval = 0
    /// The friend's police car: the last pose they sent, and its node here.
    private var remotePoliceTarget: (position: CGPoint, heading: CGFloat)?
    private var remotePolice: PoliceChase?
    private var policeBanner = SKNode()
    private var policeTitle = SKLabelNode()
    private var policeEdges: [SKShapeNode] = []
    private var policeReason = ""

    private var policeKicker = SKLabelNode()
    private var policeDistance = SKLabelNode()
    private var policeRed = SKSpriteNode()
    private var policeBlue = SKSpriteNode()
    private var policeBarFill = SKSpriteNode()
    private var policeStripe = SKSpriteNode()
    private let policeBarWidth: CGFloat = 62
    private static let policeRedColor = UIColor(red: 1, green: 0.16, blue: 0.2, alpha: 1)
    private static let policeBlueColor = UIColor(red: 0.2, green: 0.45, blue: 1, alpha: 1)

    /// Built with the HUD (hidden), so the first chase does not stall on new nodes. In the game's
    /// racing style: a slanted dark plate; on its left a light bar block whose red and blue
    /// halves strobe in turn under a beacon icon; the reason as a small spaced kicker over a big
    /// italic title; on the right how far the police is, with a bar that fills as it closes in.
    private func setupPoliceWarning() {
        policeBanner.removeFromParent()
        policeEdges.forEach { $0.removeFromParent() }
        policeEdges.removeAll()
        policeBanner = SKNode()
        // Stacked under the top bar and the turn pill; the status line and bonus texts move
        // below it while it shows
        policeBanner.position = CGPoint(x: size.width / 2 + 40, y: hudTop - 52)
        policeBanner.zPosition = 22
        // Not 0: SpriteKit skips fully transparent nodes, so the label's text would be laid out
        // only on the first chase
        policeBanner.alpha = 0.002
        let width = min(size.width - 40, 360)
        let height: CGFloat = 56
        let skew: CGFloat = 14
        let block: CGFloat = 62
        let left = -width / 2

        let plate = SKSpriteNode(texture: CarArt.policePlate(size: CGSize(width: width, height: height), skew: skew, block: block))
        plate.size = CGSize(width: width + 20, height: height + 20)
        policeBanner.addChild(plate)

        // Light bar block: red over the top half, blue under it, strobing in turn
        let stripSize = CGSize(width: block - 4, height: height / 2)
        policeRed = SKSpriteNode(texture: CarArt.policeStrip(size: stripSize, skew: skew / 2, color: ParkingScene.policeRedColor))
        policeRed.size = stripSize
        policeRed.position = CGPoint(x: left + block / 2 + 2, y: height / 4)
        policeRed.blendMode = .add
        policeBanner.addChild(policeRed)
        policeBlue = SKSpriteNode(texture: CarArt.policeStrip(size: stripSize, skew: skew / 2, color: ParkingScene.policeBlueColor))
        policeBlue.size = stripSize
        policeBlue.position = CGPoint(x: left + block / 2 - 5, y: -height / 4)
        policeBlue.blendMode = .add
        policeBanner.addChild(policeBlue)
        let beacon = makeIcon("light.beacon.max.fill", size: 22)
        beacon.position = CGPoint(x: left + block / 2 - 1, y: 0)
        policeBanner.addChild(beacon)

        // Kicker (the reason) and title
        let textX = left + block + 12
        policeKicker = SKLabelNode()
        policeKicker.horizontalAlignmentMode = .left
        policeKicker.verticalAlignmentMode = .center
        policeKicker.position = CGPoint(x: textX + 4, y: 14)
        policeBanner.addChild(policeKicker)
        policeTitle = SKLabelNode()
        policeTitle.horizontalAlignmentMode = .left
        policeTitle.verticalAlignmentMode = .center
        policeTitle.position = CGPoint(x: textX, y: -6)
        policeBanner.addChild(policeTitle)

        // Distance and the closing-in bar
        let right = width / 2 - skew - 10
        policeDistance = SKLabelNode()
        policeDistance.horizontalAlignmentMode = .right
        policeDistance.verticalAlignmentMode = .center
        policeDistance.position = CGPoint(x: right, y: 6)
        policeBanner.addChild(policeDistance)
        let track = SKSpriteNode(color: UIColor(white: 1, alpha: 0.14), size: CGSize(width: policeBarWidth, height: 4))
        track.anchorPoint = CGPoint(x: 1, y: 0.5)
        track.position = CGPoint(x: right - 4, y: -15)
        policeBanner.addChild(track)
        policeBarFill = SKSpriteNode(color: ParkingScene.policeRedColor, size: CGSize(width: policeBarWidth, height: 4))
        policeBarFill.anchorPoint = CGPoint(x: 1, y: 0.5)
        policeBarFill.position = track.position
        policeBarFill.xScale = 0.1
        policeBanner.addChild(policeBarFill)

        // Strobe line along the bottom edge
        policeStripe = SKSpriteNode(color: ParkingScene.policeRedColor, size: CGSize(width: width - skew * 2 - block, height: 2))
        policeStripe.position = CGPoint(x: left + block + (width - skew * 2 - block) / 2, y: -height / 2 + 1)
        policeStripe.blendMode = .add
        policeBanner.addChild(policeStripe)
        hud.addChild(policeBanner)
        setPoliceTexts(title: Strings.policeComing, reason: "", meters: 0)

        // Red and blue glow on the screen edges
        for (index, color) in [ParkingScene.policeRedColor, ParkingScene.policeBlueColor].enumerated() {
            let edge = SKShapeNode(rect: CGRect(x: index == 0 ? 0 : size.width - 16, y: 0, width: 16, height: size.height))
            edge.fillColor = color
            edge.strokeColor = .clear
            edge.glowWidth = 0
            edge.alpha = 0.002
            edge.zPosition = 20
            edge.blendMode = .add
            hud.addChild(edge)
            policeEdges.append(edge)
        }
    }

    private var policeTextKey = ""

    /// Lays out the warning's texts (only when they change: attributed text is not free).
    private func setPoliceTexts(title: String, reason: String, meters: Int) {
        let key = "\(title)|\(reason)|\(meters)"
        guard key != policeTextKey else { return }
        policeTextKey = key
        let kickerFont = UIFont.ui(10, .heavy)
        policeKicker.attributedText = NSAttributedString(string: Strings.upper(reason), attributes: [
            .font: kickerFont, .foregroundColor: UIColor(white: 1, alpha: 0.72), .kern: 1.6])
        policeTitle.attributedText = NSAttributedString(string: title.replacingOccurrences(of: "!", with: ""), attributes: [
            .font: CarArt.raceFont(25), .foregroundColor: UIColor.white, .kern: 0.4])
        let distance = NSMutableAttributedString(string: "\(meters)", attributes: [
            .font: UIFont.ui(22, .heavy).tabular, .foregroundColor: UIColor.white])
        distance.append(NSAttributedString(string: " M", attributes: [
            .font: UIFont.ui(10, .heavy), .foregroundColor: UIColor(white: 1, alpha: 0.6)]))
        policeDistance.attributedText = distance
    }

    /// The HUD's top line (the level/timer bar); the turn pill, police banner and status line stack under it.
    private var hudTop: CGFloat = 0
    private var policeWarningShown = false

    /// The status line (and bonus texts) under the police banner while it shows, under the turn pill otherwise.
    private func placeStatus() {
        statusLabel.position = CGPoint(x: size.width / 2 + 40, y: hudTop - (policeWarningShown ? 104 : 52))
    }

    /// The turn guidance in the top bar, or the level name (and score) when there is none.
    private func setNavShown(_ shown: Bool) {
        let show = shown && isCity
        if navNode.isHidden == !show { return }
        navNode.isHidden = !show
        levelLabel.isHidden = show
    }

    private func showPoliceWarning(_ reason: String) {
        if policeBanner.parent == nil { setupPoliceWarning() }
        policeWarningShown = true
        placeStatus()
        policeReason = reason
        // Drops in from just above with a slight overshoot
        policeBanner.removeAllActions()
        let home = CGPoint(x: size.width / 2 + 40, y: hudTop - 52)
        policeBanner.position = CGPoint(x: home.x, y: home.y + 16)
        policeBanner.alpha = 0
        policeBanner.setScale(1)
        let drop = SKAction.move(to: home, duration: 0.28)
        drop.timingMode = .easeOut
        policeBanner.run(.group([drop, .fadeIn(withDuration: 0.18)]))
        audio.play("beep", volume: 0.6)
    }

    private func hidePoliceWarning() {
        policeWarningShown = false
        placeStatus()
        policeBanner.removeAllActions()
        policeBanner.run(.fadeAlpha(to: 0.002, duration: 0.3))
        policeEdges.forEach { $0.run(.fadeAlpha(to: 0.002, duration: 0.3)) }
    }

    private func updatePoliceWarning(_ chase: PoliceChase) {
        let meters = Int((chase.distance / 10).rounded())
        let title = chase.pursuing ? Strings.policeChase : Strings.policeComing
        setPoliceTexts(title: title, reason: policeReason, meters: meters)
        let flash = Int(lastUpdate * 6) % 2 == 0
        policeRed.alpha = flash ? 1 : 0.18
        policeBlue.alpha = flash ? 0.18 : 1
        policeStripe.color = flash ? ParkingScene.policeRedColor : ParkingScene.policeBlueColor
        // How close it is: the bar fills from 60 m away to the catch
        let close = max(0.04, min(1, 1 - (chase.distance - 34) / 566))
        policeBarFill.xScale += (close - policeBarFill.xScale) * 0.25
        policeBarFill.color = close > 0.75 ? ParkingScene.policeRedColor : UIColor(red: 1, green: 0.72, blue: 0.2, alpha: 1)
        // The closer the police, the stronger the edge glow
        let strength = max(0.25, min(0.7, 0.8 - chase.distance / 1500))
        if policeEdges.count == 2 {
            policeEdges[0].alpha = flash ? strength : strength * 0.15
            policeEdges[1].alpha = flash ? strength * 0.15 : strength
        }
    }

    // MARK: Collisions

    private struct CarImpact {
        let contact: Contact
        let center: CGPoint
        let otherVelocity: CGVector
        /// Speed at which the two cars approach each other (world units/s).
        let closing: CGFloat
    }

    /// A moving car (traffic or friend) the move would run into, with the closing speed.
    private func carImpact(_ box: OBB, to newPosition: CGPoint) -> CarImpact? {
        let mine = CGVector(dx: cos(heading) * velocity, dy: sin(heading) * velocity)
        var best: CarImpact?
        for contact in contacts(box) {
            var other: CGVector
            switch contact {
            case .bot(let index):
                guard let bots = traffic?.bots, index < bots.count else { continue }
                let bot = bots[index]
                other = CGVector(dx: cos(bot.heading) * bot.speed, dy: sin(bot.heading) * bot.speed)
            case .remoteCar:
                let v = remoteSnapshots.last?.velocity ?? 0
                other = CGVector(dx: cos(remoteHeading) * v, dy: sin(remoteHeading) * v)
            default:
                continue
            }
            guard let c = center(of: contact) else { continue }
            let dx = c.x - carPosition.x, dy = c.y - carPosition.y
            let length = max(1, hypot(dx, dy))
            let closing = ((mine.dx - other.dx) * dx + (mine.dy - other.dy) * dy) / length
            // Only when we actually move into it (otherwise the cars just separate)
            let oldDistance = hypot(carPosition.x - c.x, carPosition.y - c.y)
            let newDistance = hypot(newPosition.x - c.x, newPosition.y - c.y)
            guard closing > 10 || newDistance < oldDistance - 0.01 else { continue }
            if best == nil || closing > best!.closing {
                best = CarImpact(contact: contact, center: c, otherVelocity: other, closing: closing)
            }
        }
        return best
    }

    /// Car-on-car crash as momentum, the way racing games settle it: two cars of about the same
    /// weight trade the speed at which they close along the line between them, and as cars crumple
    /// rather than bounce only a little comes back (restitution 0.25); scraping along each other
    /// takes some of the sliding speed too. A hit away from a car's middle turns it, as much as
    /// the lever of the blow and its length allow, so a nudge on a rear corner swings the tail but
    /// a straight rear-end or a head-on barely turns either car. Both get exactly opposite shoves.
    private func crashCar(_ impact: CarImpact) {
        failDrift()
        let dx = impact.center.x - carPosition.x, dy = impact.center.y - carPosition.y
        let length = max(1, hypot(dx, dy))
        let nx = dx / length, ny = dy / length                       // from us to the other car
        let mine = CGVector(dx: cos(heading) * velocity, dy: sin(heading) * velocity)
        let relative = CGVector(dx: mine.dx - impact.otherVelocity.dx, dy: mine.dy - impact.otherVelocity.dy)
        let restitution: CGFloat = 0.25
        let normalImpulse = (1 + restitution) / 2 * max(0, impact.closing)  // per car, equal masses
        // Friction between the bodies: some of the sliding along each other is taken out
        let along = relative.dx * nx + relative.dy * ny
        let slideX = relative.dx - nx * along, slideY = relative.dy - ny * along
        let slide = hypot(slideX, slideY)
        let scrape = slide > 1 ? min(slide / 2, 0.35 * normalImpulse) / slide : 0
        // Our change of velocity; the other car gets the opposite
        let change = CGVector(dx: -nx * normalImpulse - slideX * scrape, dy: -ny * normalImpulse - slideY * scrape)
        applyImpulse(change, contactFrom: impact.center)
        let otherHeading: CGFloat
        switch impact.contact {
        case .bot(let index): otherHeading = traffic?.bots.indices.contains(index) == true ? traffic!.bots[index].heading : heading
        default: otherHeading = remoteHeading
        }
        let otherChange = CGVector(dx: -change.dx, dy: -change.dy)
        let otherSpin = CarPhysics.spin(from: otherChange, at: carPosition, carCenter: impact.center, carHeading: otherHeading)
        let strength = max(0.1, min(1, normalImpulse / (maxForward * 0.5)))
        if case .bot(let index) = impact.contact {
            traffic?.hit(index, shove: otherChange, spin: otherSpin)
        }
        if case .remoteCar = impact.contact, online, friendPresent {
            // The friend's game simulates the friend's car: tell it about the hit, or on the
            // friend's screen nothing happens (each player only ever saw their own side of a crash)
            let point = CGPoint(x: (carPosition.x + impact.center.x) / 2, y: (carPosition.y + impact.center.y) / 2)
            if benchmark { netLog(String(format: "hit sent closing=%.0f", impact.closing)) }
            model?.send(["t": "hit", "l": levelIndex, "dx": Double(otherChange.dx), "dy": Double(otherChange.dy),
                         "sp": Double(otherSpin), "k": Double(strength), "dv": 1,
                         "x": Double(point.x), "y": Double(point.y)])
        }
        var clock = CACurrentMediaTime()
        func lap(_ name: String) {
            guard benchmark else { return }
            let now = CACurrentMediaTime()
            FileHandle.standardError.write(String(format: "PPTIME %@ %.2f ms\n", name, (now - clock) * 1000).data(using: .utf8)!)
            clock = now
        }
        audio.play("crash", volume: Float(min(1, 0.45 + strength * 0.6)))
        lap("audio")
        bumpHaptic.impactOccurred(intensity: min(1, 0.6 + strength * 0.4))
        lap("haptic")
        world?.shake(strength: 3 + 7 * strength)
        dispatchPolice(Strings.crimeCrash)
        lap("police")
        sparks(at: CGPoint(x: (carPosition.x + impact.center.x) / 2, y: (carPosition.y + impact.center.y) / 2))
        dust(at: CGPoint(x: (carPosition.x + impact.center.x) / 2, y: (carPosition.y + impact.center.y) / 2))
        lap("sparks")
        // People nearby jump at the bang, turn to look, then get angry
        pendingHorn = CGPoint(x: (carPosition.x + impact.center.x) / 2, y: (carPosition.y + impact.center.y) / 2)
    }

    /// A sudden change of velocity: the part along the car changes its speed, the part across it
    /// becomes a sideways slide the tyres scrub off, and the blow turns the car about its middle.
    private func applyImpulse(_ change: CGVector, contactFrom other: CGPoint) {
        let forwardX = cos(heading), forwardY = sin(heading)
        let along = change.dx * forwardX + change.dy * forwardY
        velocity += along
        crashShove = CGVector(dx: crashShove.dx + change.dx - forwardX * along,
                              dy: crashShove.dy + change.dy - forwardY * along)
        crashSpin += CarPhysics.spin(from: change, at: other, carCenter: carPosition, carHeading: heading)
    }

    /// The friend drove into us (their game saw the hit): our car takes the shove and the spin they
    /// worked out, with the crunch, the shake and the sparks. It does not count as our crash.
    private func friendHitUs(_ message: [String: Any]) {
        guard phase == .driving, !localParked else { return }
        let dx = CGFloat(message["dx"] as? Double ?? 0), dy = CGFloat(message["dy"] as? Double ?? 0)
        let spin = CGFloat(message["sp"] as? Double ?? 0)
        let strength = CGFloat(message["k"] as? Double ?? 0.5)
        hitByFriendAt = lastUpdate
        if benchmark {
            netLog(String(format: "hit received shove=%.0f seen=%.0f delay=%.0fms", hypot(dx, dy),
                          carPosition.distance(to: remotePosition), oneWayDelay * 1000))
        }
        failDrift()
        if message["dv"] != nil {
            // A change of velocity worked out from both cars' momentum
            let forwardX = cos(heading), forwardY = sin(heading)
            let along = dx * forwardX + dy * forwardY
            velocity += along
            crashShove = CGVector(dx: crashShove.dx + dx - forwardX * along, dy: crashShove.dy + dy - forwardY * along)
            crashSpin += max(-CarPhysics.maxSpin, min(CarPhysics.maxSpin, spin))
        } else {
            crashShove = CGVector(dx: crashShove.dx + dx, dy: crashShove.dy + dy)
            crashSpin += spin
            velocity *= 0.6
        }
        audio.play("crash", volume: Float(min(1, 0.45 + strength * 0.6)))
        bumpHaptic.impactOccurred(intensity: min(1, 0.6 + strength * 0.4))
        world?.shake(strength: 3 + 7 * strength)
        let point = CGPoint(x: message["x"] as? Double ?? Double(carPosition.x), y: message["y"] as? Double ?? Double(carPosition.y))
        sparks(at: point)
        dust(at: point)
    }

    /// A real crash (into a car, or a wall at speed): crunch sound, a shove away from the hit and a
    /// spin that depends on where the hit landed, like arcade racers. The traffic car we hit is
    /// shoved and spun too. Returns false for light bumps.
    private func crash(into box: OBB, impact: CGFloat) -> Bool {
        let before = contacts(OBB(center: carPosition, size: Levels.carSize, angle: heading))
        let new = contacts(box).subtracting(before)
        let hitCar = new.contains { if case .bot = $0 { return true }; if case .remoteCar = $0 { return true }; return false }
        guard impact > (hitCar ? 35 : 70) else { return false }
        let strength = min(1, impact / maxForward)
        // Where the other thing is: the side of the hit decides the spin direction
        var other = CGPoint(x: carPosition.x + cos(heading) * 30 * (velocity >= 0 ? 1 : -1),
                            y: carPosition.y + sin(heading) * 30 * (velocity >= 0 ? 1 : -1))
        for contact in new { if let c = center(of: contact) { other = c; break } }
        let dx = other.x - carPosition.x, dy = other.y - carPosition.y
        let length = max(1, hypot(dx, dy))
        let side = cos(heading) * dy - sin(heading) * dx          // > 0: the hit is on our left
        let forwardness = (cos(heading) * dx + sin(heading) * dy) / length
        let spinSign: CGFloat = side >= 0 ? -1 : 1
        // A parked car or a wall does not move: the car comes off it with little rebound and only
        // turns much when the blow lands well off its middle
        crashSpin = spinSign * (0.6 + 1.6 * strength) * (0.35 + 0.65 * (1 - abs(forwardness)))
        let push = 25 + 75 * strength
        crashShove = CGVector(dx: -dx / length * push, dy: -dy / length * push)
        for contact in new {
            if case .bot(let index) = contact {
                // Our momentum goes into the other car
                let travel = velocity >= 0 ? heading : heading + CGFloat.pi
                traffic?.hit(index, shove: CGVector(dx: cos(travel) * impact * 0.6, dy: sin(travel) * impact * 0.6),
                             spin: -spinSign * (0.5 + 1.3 * strength))
            }
        }
        audio.play("crash", volume: Float(min(1, 0.5 + strength * 0.6)))
        bumpHaptic.impactOccurred(intensity: 1.0)
        world?.shake(strength: 3 + 7 * strength)
        sparks(at: CGPoint(x: (carPosition.x + other.x) / 2, y: (carPosition.y + other.y) / 2))
        dispatchPolice(hitCar ? Strings.crimeCrash : Strings.crimeReckless)
        return true
    }

    /// Parked cars the car runs into rock on their springs.
    private func rockHitCars(_ box: OBB, speed: CGFloat) {
        let travel = velocity >= 0 ? heading : heading + .pi
        for contact in contacts(box) {
            guard case .obstacle(let index) = contact, index < level.obstacles.count, level.obstacles[index].kind == .car else { continue }
            world?.rockParkedCar(near: obstacleBoxes[index].center, direction: travel, strength: speed / 90)
        }
    }

    /// Slides and spins the car after a crash; both fade out within about a second.
    private func applyCrashMotion(_ dt: CGFloat) {
        guard abs(crashSpin) > 0.02 || hypot(crashShove.dx, crashShove.dy) > 2 else {
            crashSpin = 0
            crashShove = .zero
            return
        }
        let candidate = CGPoint(x: carPosition.x + crashShove.dx * dt, y: carPosition.y + crashShove.dy * dt)
        let turned = heading + crashSpin * dt
        let box = OBB(center: candidate, size: Levels.carSize, angle: turned)
        if !blocked(moving: box, to: candidate) {
            carPosition = candidate
            heading = turned
        } else if !blocked(moving: OBB(center: carPosition, size: Levels.carSize, angle: turned), to: carPosition) {
            heading = turned
            crashShove = .zero
        } else {
            crashShove = .zero
            crashSpin = 0
        }
        // The tyres scrub off the sideways slide and the spin (about half of each is gone in a
        // sixth of a second)
        let fade = exp(-dt * 4.2)
        crashShove = CGVector(dx: crashShove.dx * fade, dy: crashShove.dy * fade)
        crashSpin *= fade
        // Tyres screech while the car spins
        if abs(crashSpin) > 1.0 {
            skidClock += dt
            if skidClock > 0.03 {
                skidClock = 0
                for side: CGFloat in [10, -10] {
                    world?.addSkid(at: CGPoint(x: carPosition.x - 13 * cos(heading) - side * sin(heading),
                                               y: carPosition.y - 13 * sin(heading) + side * cos(heading)))
                }
            }
        }
    }

    private var remoteBox: OBB { OBB(center: remotePosition, size: Levels.carSize, angle: remoteHeading) }

    /// Cones are knocked over, not driven against: they never block the car.
    private var coneIndices = Set<Int>()
    private var knockedCones = Set<Int>()
    /// Where the last hit was counted: pressing on against the same wall or car is not a new hit.
    private var lastHitPosition = CGPoint(x: -9999, y: -9999)

    /// A hit counts once per contact: not again while the car is still pressed against the same
    /// thing (it used to count again every 0.6 s with the throttle held against a wall).
    private func freshHit() -> Bool {
        carPosition.distance(to: lastHitPosition) > 30 || lastUpdate - lastHitAt > 2.5
    }

    private func countHit() {
        lastHitAt = lastUpdate
        lastHitPosition = carPosition
        hits += 1
        if benchmark { FrameMonitor.shared.mark("hit") }
        hitsLabel.text = "\(hits)"
    }

    /// Cones the car runs into fly off and fall over; each counts as a hit (as on a driving test).
    private func knockCones() {
        guard !coneIndices.isEmpty, coneIndices.count > knockedCones.count else { return }
        // The cone is hit only where it is drawn: its round body (8 units across at the foot, the
        // 3D cone in World3D) against the car's painted body, which is a little narrower than the
        // collision box. The cone's square 14-unit box and the full car box knocked cones over a
        // hand's width before the car reached them, worst at the box corners.
        let bodyHalf = CGSize(width: Levels.carSize.width / 2 - 0.5, height: Levels.carSize.height / 2 - 1.5)
        let coneRadius: CGFloat = 4.5
        let u = CGVector(dx: cos(heading), dy: sin(heading))
        for index in coneIndices where !knockedCones.contains(index) && index < obstacleBoxes.count {
            let cone = obstacleBoxes[index]
            let dx = cone.center.x - carPosition.x
            let dy = cone.center.y - carPosition.y
            guard abs(dx) < 45, abs(dy) < 45 else { continue }
            // The cone's centre in the car's frame, then the nearest point of the body to it
            let along = dx * u.dx + dy * u.dy
            let across = -dx * u.dy + dy * u.dx
            let gapAlong = max(0, abs(along) - bodyHalf.width)
            let gapAcross = max(0, abs(across) - bodyHalf.height)
            guard gapAlong * gapAlong + gapAcross * gapAcross < coneRadius * coneRadius else { continue }
            knockedCones.insert(index)
            let speed = abs(velocity)
            let travel = velocity >= 0 ? heading : heading + .pi
            // Thrown along the car's way, a little off to the side it was hit on
            let away = atan2(cone.center.y - carPosition.y, cone.center.x - carPosition.x)
            let direction = travel + CGFloat.angleDelta(travel, away) * 0.4
            world?.knockCone(index, direction: direction, speed: max(speed, 20))
            audio.play("bump", volume: Float(min(0.6, 0.25 + speed / 300)))
            bumpHaptic.impactOccurred(intensity: min(1, 0.45 + speed / 200))
            world?.shake(strength: min(3, 1 + speed / 60))
            dust(at: cone.center)
            velocity *= 0.9
            if speed > 4 && lastUpdate - lastHitAt > 0.25 {
                countHit()
                dispatchPolice(Strings.crimeReckless)
            }
        }
    }

    private func contacts(_ box: OBB, includeRemote: Bool = true) -> Set<Contact> {
        var result = Set<Contact>()
        let world = level.world
        let curb: CGFloat = isCity ? 4 : 8
        for corner in box.corners {
            if corner.x < curb || corner.y < curb || corner.x > world.width - curb || corner.y > world.height - curb {
                result.insert(.bounds)
                break
            }
        }
        for (index, obstacle) in obstacleBoxes.enumerated() where !coneIndices.contains(index) {
            let dx = obstacle.center.x - box.center.x
            let dy = obstacle.center.y - box.center.y
            let limit = 60 + max(obstacle.halfSize.width, obstacle.halfSize.height)
            if abs(dx) > limit || abs(dy) > limit { continue }
            if box.intersects(obstacle) { result.insert(.obstacle(index)) }
        }
        if includeRemote && friendPresent && remoteTarget != nil && box.intersects(remoteBox) {
            result.insert(.remoteCar)
        }
        if let traffic = traffic {
            for (index, bot) in traffic.bots.enumerated() {
                if abs(bot.position.x - box.center.x) > 60 || abs(bot.position.y - box.center.y) > 60 { continue }
                if box.intersects(bot.box) { result.insert(.bot(index)) }
            }
        }
        return result
    }

    private func center(of contact: Contact) -> CGPoint? {
        switch contact {
        case .bounds: return nil
        case .obstacle(let index): return obstacleBoxes[index].center
        case .remoteCar: return remotePosition
        case .bot(let index):
            guard let bots = traffic?.bots, index < bots.count else { return nil }
            return bots[index].position
        }
    }

    /// A move is blocked by any new contact. Contacts that already exist (for example when the
    /// other car drove into us) only block moves that go deeper, so the cars can always separate.
    private func blocked(moving box: OBB, to newPosition: CGPoint) -> Bool {
        let before = contacts(OBB(center: carPosition, size: Levels.carSize, angle: heading))
        let after = contacts(box)
        for contact in after {
            guard before.contains(contact) else { return true }
            if let c = center(of: contact) {
                let oldDistance = hypot(carPosition.x - c.x, carPosition.y - c.y)
                let newDistance = hypot(newPosition.x - c.x, newPosition.y - c.y)
                if newDistance < oldDistance - 0.01 { return true }
            }
        }
        return false
    }

    /// Which way the wall the car is touching faces (level units, pointing away from it): probes
    /// a car-sized box a little way out in sixteen directions and averages the blocked ones.
    /// Turns the car on the spot the way the wheel points (and eases it off the wall), so a car
    /// pressed against a wall can steer away under throttle. Returns whether it could turn.
    private func pivotOffWall(_ dt: CGFloat, reverse: Bool) -> Bool {
        let normal = wallNormal() ?? .zero
        let turn = (wheelInput > 0 ? 1 : -1) * (reverse ? -1 : 1) * (1.6 + 1.2 * abs(wheelInput)) * dt
        for (push, factor) in [(CGFloat(0.6), CGFloat(1)), (1.4, 1), (0.6, 0.5), (2.2, 1)] {
            let h = heading + turn * factor
            let candidate = CGPoint(x: carPosition.x + normal.dx * push, y: carPosition.y + normal.dy * push)
            if !blocked(moving: OBB(center: candidate, size: Levels.carSize, angle: h), to: candidate) {
                carPosition = candidate
                heading = h
                if drifting { travelHeading = h - driftSlip }
                // Once the nose points away from the wall, the car rolls off along its heading
                let step = CGPoint(x: candidate.x + cos(h) * (reverse ? -1 : 1) * 30 * dt,
                                   y: candidate.y + sin(h) * (reverse ? -1 : 1) * 30 * dt)
                if !blocked(moving: OBB(center: step, size: Levels.carSize, angle: h), to: step) { carPosition = step }
                return true
            }
        }
        return false
    }

    private func wallNormal() -> CGVector? {
        var sum = CGVector.zero
        var found = 0
        for k in 0..<16 {
            let a = CGFloat(k) / 16 * 2 * .pi
            let d = CGVector(dx: cos(a), dy: sin(a))
            let probe = CGPoint(x: carPosition.x + d.dx * 4, y: carPosition.y + d.dy * 4)
            if !contacts(OBB(center: probe, size: Levels.carSize, angle: heading), includeRemote: false).isEmpty {
                sum.dx -= d.dx
                sum.dy -= d.dy
                found += 1
            }
        }
        let length = hypot(sum.dx, sum.dy)
        guard found > 0, found < 14, length > 0.01 else { return nil }
        return CGVector(dx: sum.dx / length, dy: sum.dy / length)
    }

    /// When the two cars overlap, nudge ours away from the other one.
    private func separateFromRemote(_ dt: CGFloat) {
        guard friendPresent, remoteTarget != nil else { return }
        let mine = OBB(center: carPosition, size: Levels.carSize, angle: heading)
        guard mine.intersects(remoteBox) else { return }
        var dx = carPosition.x - remotePosition.x
        var dy = carPosition.y - remotePosition.y
        var length = hypot(dx, dy)
        if length < 0.5 {
            dx = cos(heading + CGFloat.pi / 2)
            dy = sin(heading + CGFloat.pi / 2)
            length = 1
        }
        let push = 45 * dt
        let candidate = CGPoint(x: carPosition.x + dx / length * push, y: carPosition.y + dy / length * push)
        let candidateBox = OBB(center: candidate, size: Levels.carSize, angle: heading)
        if contacts(candidateBox, includeRemote: false).isEmpty {
            carPosition = candidate
        }
    }

    // MARK: Effects

    private func tyreEffects(_ dt: CGFloat, accelerating: Bool) {
        // As in a real car the tyres stay quiet through an ordinary turn: they only squeal once
        // they slide, from a faint hiss right at the limit of grip to a full screech when the car
        // runs wide, the tail steps out or it drifts; braking squeals only when it is hard enough
        // at speed to lock up. Nothing at walking pace.
        let speed = abs(velocity)
        let speedShare = min(1, speed / max(maxForward, 1))
        let atLimit = max(0, min(1, (gripUse - 0.9) / 0.1))           // last 10% of the grip
        let tail = min(1, abs(skid) / 0.25)                             // the tail stepping out
        let lockUp = braking && speedShare > 0.55 ? (speedShare - 0.55) / 0.45 : 0
        var slip = max(atLimit * 0.25, understeer, tail, lockUp * 0.6)
        if drifting { slip = max(slip, 0.85) }
        if speed < 40 || airTime > 0 { slip = 0 }
        let target = slip * (0.35 + 0.65 * min(1, speed / 160))
        // Rises quickly as the tyres let go, fades as they bite again
        squealLevel += (target - squealLevel) * min(1, dt * (target > squealLevel ? 12 : 5))
        audio.setSkid(volume: Float(squealLevel * 0.5), rate: Float(0.88 + 0.22 * slip + 0.12 * speedShare))
        // Marks only where the rubber actually slides
        let sliding = drifting || understeer > 0.15 || tail > 0.3 || lockUp > 0.35
        skidClock += dt
        if sliding && speed > 40 && airTime <= 0 && skidClock > 0.03 {
            skidClock = 0
            for side: CGFloat in [10, -10] {
                let point = CGPoint(x: carPosition.x - 13 * cos(heading) - side * sin(heading),
                                    y: carPosition.y - 13 * sin(heading) + side * cos(heading))
                world?.addSkid(at: point)
            }
        }

        // Wind noise grows with speed
        audio.setLoop("wind", volume: Float(max(0, min(0.4, (speed / maxForward - 0.45) * 0.45))))

        smokeClock += dt
        if accelerating && abs(velocity) < 45 && abs(longitudinalAccel) > 90 && smokeClock > 0.06 {
            smokeClock = 0
            let back: CGFloat = velocity >= 0 ? -1 : 1
            let point = CGPoint(x: carPosition.x + cos(heading) * 22 * back, y: carPosition.y + sin(heading) * 22 * back)
            guard let screen = world?.project(point, height: 0.4) else { return }
            let puff = SKSpriteNode(texture: dotTexture)
            puff.size = CGSize(width: 12, height: 12)
            puff.position = screen
            puff.alpha = 0.35
            fxLayer.addChild(puff)
            puff.run(.sequence([
                .group([.scale(to: 3.2, duration: 0.7), .fadeOut(withDuration: 0.7),
                        .moveBy(x: CGFloat.random(in: -10...10), y: CGFloat.random(in: 2...14), duration: 0.7)]),
                .removeFromParent()
            ]))
        }
    }

    private func dust(at point: CGPoint) {
        guard let screen = world?.project(point, height: 0.6) else { return }
        for _ in 0..<8 {
            let puff = SKSpriteNode(texture: dotTexture)
            puff.size = CGSize(width: 10, height: 10)
            puff.color = UIColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1)
            puff.colorBlendFactor = 1
            puff.position = screen
            puff.alpha = 0.65
            fxLayer.addChild(puff)
            puff.run(.sequence([
                .group([.moveBy(x: CGFloat.random(in: -22...22), y: CGFloat.random(in: -10...24), duration: 0.45),
                        .scale(to: 2.2, duration: 0.45), .fadeOut(withDuration: 0.45)]),
                .removeFromParent()
            ]))
        }
    }

    /// Sparks and bits flying from a crash point.
    private func sparks(at point: CGPoint) {
        guard let screen = world?.project(point, height: 0.7) else { return }
        for index in 0..<16 {
            let spark = SKSpriteNode(texture: dotTexture)
            let hot = index % 3 != 0
            spark.size = hot ? CGSize(width: 5, height: 5) : CGSize(width: 7, height: 7)
            spark.color = hot ? UIColor(red: 1.0, green: 0.78, blue: 0.3, alpha: 1) : UIColor(white: 0.85, alpha: 1)
            spark.colorBlendFactor = 1
            spark.blendMode = hot ? .add : .alpha
            spark.position = screen
            fxLayer.addChild(spark)
            let angle = CGFloat.random(in: 0...(2 * CGFloat.pi))
            let distance = CGFloat.random(in: 30...85)
            let move = SKAction.moveBy(x: cos(angle) * distance, y: sin(angle) * distance * 0.7 + 12, duration: 0.4)
            move.timingMode = .easeOut
            spark.run(.sequence([.group([move, .fadeOut(withDuration: 0.4), .scale(to: 0.3, duration: 0.4)]),
                                 .removeFromParent()]))
        }
        dust(at: point)
    }

    // MARK: Parking

    private func checkParking(_ dt: CGFloat) {
        if level.taxi != nil && taxiState != .riding { return }
        if level.race {
            if level.spots[slot].box.contains(carPosition) { parked() }
            return
        }
        let spot = level.spots[slot]
        let spotBox = spot.box
        let carBox = OBB(center: carPosition, size: Levels.carSize, angle: heading)
        let inside = carBox.corners.allSatisfy { spotBox.contains($0) }
        let misalignment = abs((heading - spot.angle).remainder(dividingBy: CGFloat.pi))
        let aligned = misalignment < challenge.alignTolerance
        let slowEnough = abs(velocity) < 14 && !isPressed(.forward) && !isPressed(.reverse)
        // Backing in: the nose must point toward the lane (where the car came from)
        var facingOut = true
        if challenge.reverseIn {
            let axis = CGVector(dx: cos(spot.angle), dy: sin(spot.angle))
            let start = level.starts[min(slot, level.starts.count - 1)].position
            let outward = (start.x - spot.center.x) * axis.dx + (start.y - spot.center.y) * axis.dy >= 0 ? 1.0 : -1.0
            facingOut = (cos(heading) * axis.dx + sin(heading) * axis.dy) * outward > 0
        }

        if inside && aligned && slowEnough && !facingOut {
            parkHold = 0
            statusLabel.text = Strings.reverseHint
        } else if inside && !aligned && slowEnough && challenge.number >= 25 {
            parkHold = max(0, parkHold - dt * 2)
            statusLabel.text = Strings.straightenHint
        } else if inside && aligned && slowEnough {
            parkHold += dt
            velocity = approach(velocity, 0, 60 * dt)
            if [Strings.reverseHint, Strings.straightenHint].contains(statusLabel.text ?? "") { statusLabel.text = "" }
        } else {
            parkHold = max(0, parkHold - dt * 2)
            if [Strings.hold, Strings.reverseHint, Strings.straightenHint].contains(statusLabel.text ?? "") { statusLabel.text = "" }
        }

        let progress = min(parkHold / challenge.holdTime, 1)
        setHold(parkHold > 0.01 ? progress : nil)
        // The marker over the bay is not needed once the car is in it
        world?.setTargetMarker(hidden: inside, progress: inside ? progress : 0)

        if parkHold >= challenge.holdTime {
            parked()
        }
    }

    /// Shows the hold capsule with its bar at `progress` (nil hides it).
    private func setHold(_ progress: CGFloat?) {
        if let progress = progress {
            holdFill.xScale = max(0.001, progress)
            if !holdShown {
                holdShown = true
                if benchmark {
                    run(.wait(forDuration: 0.4)) { saveWindowSnapshot(named: "shot-hold") }
                }
                holdLabel.text = Strings.hold.localUpper
                holdModule.removeAllActions()
                holdModule.position = holdHome
                holdModule.setScale(0.95)
                holdModule.run(.group([.fadeIn(withDuration: 0.15), .scale(to: 1, duration: 0.15)]))
            }
        } else if holdShown {
            holdShown = false
            holdModule.removeAllActions()
            holdModule.run(.fadeOut(withDuration: 0.2))
        }
    }

    private func parked() {
        localParked = true
        localTime = elapsed
        // Spot Wars: this bay is ours now (hunters still on their way to it look elsewhere)
        if spotWars && spotTarget >= 0 { traffic?.claim(spotTarget) }
        if taxiState == .riding { taxiState = .delivered }
        // Drifting into the spot (or the finish) takes 2 s off
        if (drifting || lastUpdate - lastDriftEnd < 2.5) && max(driftScore, lastDriftScore) > 40 {
            localTime = max(0, localTime - 2)
            flashBonus(Strings.driftPark)
        }
        if drifting { endDrift() }
        endPoliceChase()
        squealLevel = 0
        audio.setLoop("skid", volume: 0)
        audio.setLoop("wind", volume: 0)
        audio.setLoop("siren", volume: 0)
        if !level.race { velocity = 0 }
        braking = false
        longitudinalAccel = 0
        lateralAccel = 0
        phase = .finished
        holdRing.path = nil
        holdFill.xScale = 1
        holdLabel.text = Strings.parked.localUpper
        holdModule.run(.sequence([.wait(forDuration: 0.6), .fadeOut(withDuration: 0.25)]))
        holdShown = false
        world?.setTargetMarker(hidden: true, progress: 1)
        world?.markParked()
        notifyHaptic.notificationOccurred(.success)
        audio.play("park", volume: 0.9)
        statusLabel.text = ""

        model?.send(["t": "p", "l": levelIndex, "time": localTime, "hits": hits,
                     "x": Double(carPosition.x), "y": Double(carPosition.y), "h": Double(heading)])
        if !isCity {
            model?.levelCompleted(levelIndex)
            newBest = model?.record(level: levelIndex, time: localTime, hits: hits) ?? false
            if newBest { saveGhost() }
        }
        if !isCity && !level.race {
            let precision = ParkPrecision(spot: level.spots[slot], car: carPosition, heading: heading, carSize: Levels.carSize)
            lastPrecision = precision
            precisionBest = ParkPrecision.record(level: levelIndex, score: precision.score)
        } else if level.taxi != nil {
            // The drop-off is measured too: the tip grows with it
            lastPrecision = ParkPrecision(spot: level.spots[slot], car: carPosition, heading: heading, carSize: Levels.carSize)
        }
        if level.race {
            playFinishSequence()
        } else {
            playParkedSequence()
        }
    }

    /// Finish line moment. Everything it shows is prepared while the level loads, so it starts on
    /// the very frame the car crosses the line:
    /// 0.0 s  the scene dims at the edges and the title builds letter by letter; slow motion, low camera
    /// 1.0 s  cut to an orbit around the car with fireworks and confetti
    /// 4.0 s  the title eases out, results card
    private func playFinishSequence() {
        if benchRecording { finishCrossAt = Double(benchClock - 2) }
        finishAnimating = true
        finishClock = 0
        world?.startFinishCinematic(at: carPosition, heading: heading, finishLine: level.spots[slot].center)
        audio.play("nitro", volume: 0.45)
        notifyHaptic.notificationOccurred(.success)

        let layer = SKNode()
        layer.zPosition = 300
        addChild(layer)
        for node in [hud, controlsLayer, fxLayer] {
            node.run(.sequence([.fadeOut(withDuration: 0.25), .wait(forDuration: 2.3), .fadeIn(withDuration: 0.3)]))
        }
        speedLines.forEach { $0.sprite.alpha = 0.002 }

        run(.wait(forDuration: 1.0)) { [weak self] in self?.finishShotB(layer: layer) }
        if benchmark {
            // After the critical first second, so the capture does not count as a finish hitch
            run(.wait(forDuration: 2.2)) { Task { @MainActor in saveWindowSnapshot(named: "shot-finish") } }
        }
        // (no title of its own: the same results screen as every other mode follows the shots)
        layer.run(.sequence([.wait(forDuration: 2.9), .removeFromParent()]))
        run(.wait(forDuration: 2.8)) { [weak self] in
            guard let self = self else { return }
            self.finishAnimating = false
            self.checkLevelDone()
        }
    }

    /// Finish title, laid out like a broadcast lower third so the car stays in view: a dark scrim
    /// from the left, a kicker with an accent tick, the title's letters dropping in one by one
    /// with a shine across them, and one glass panel of stats (label over a big number) sliding
    /// up beneath. Golden sparks drift up; everything eases out together after `hold`.
    private func presentFinishTitle(in layer: SKNode, title: String, kicker: String,
                                    stats: [CarArt.FinishStat], accent: UIColor, hold: TimeInterval) {
        let left = max(36, size.width * 0.075)
        let group = SKNode()
        group.position = CGPoint(x: left, y: size.height * 0.5)
        layer.addChild(group)

        // Scrim: dark on the left where the text sits, clear over the car
        let scrim = SKSpriteNode(texture: CarArt.finishScrim)
        scrim.size = CGSize(width: size.width * 0.72, height: size.height)
        scrim.anchorPoint = CGPoint(x: 0, y: 0.5)
        scrim.position = CGPoint(x: 0, y: size.height / 2)
        scrim.alpha = 0
        scrim.zPosition = -2
        layer.addChild(scrim)
        scrim.run(.fadeAlpha(to: 1, duration: 0.4))

        // Kicker: dark text on an accent capsule, unrolling from the left
        let kickerLabel = SKLabelNode(text: kicker)
        kickerLabel.fontName = "Barlow-ExtraBold"
        kickerLabel.fontSize = 12
        kickerLabel.fontColor = UIColor(red: 0.06, green: 0.07, blue: 0.12, alpha: 1)
        kickerLabel.horizontalAlignmentMode = .left
        kickerLabel.verticalAlignmentMode = .center
        let kickerWidth = kickerLabel.frame.width + 26
        let chip = SKShapeNode(rect: CGRect(x: 0, y: -12, width: kickerWidth, height: 24), cornerRadius: 12)
        chip.fillColor = accent
        chip.strokeColor = .clear
        chip.position = CGPoint(x: 2, y: 70)
        kickerLabel.position = CGPoint(x: 13, y: 0)
        chip.addChild(kickerLabel)
        chip.xScale = 0.001
        chip.alpha = 0
        group.addChild(chip)
        let unroll = SKAction.scaleX(to: 1, duration: 0.3)
        unroll.timingMode = .easeOut
        chip.run(.sequence([.wait(forDuration: 0.05), .group([.fadeIn(withDuration: 0.12), unroll])]))

        // Letters, left-aligned
        let glyphs = finishGlyphs[title] ?? CarArt.titleGlyphs(title, size: 88)
        let total = glyphs.reduce(0) { $0 + $1.advance }
        let pad = glyphs.first.map { ($0.texture.size().width - $0.advance) / 2 } ?? 0
        var x: CGFloat = -pad * 0.6
        for (index, glyph) in glyphs.enumerated() {
            let letter = SKSpriteNode(texture: glyph.texture)
            letter.size = glyph.texture.size()
            let home = CGPoint(x: x + glyph.advance / 2, y: 4)
            x += glyph.advance
            letter.position = CGPoint(x: home.x - 30, y: home.y)
            letter.alpha = 0
            letter.xScale = 1.25
            group.addChild(letter)
            let delay = 0.12 + Double(index) * 0.04
            let slide = SKAction.move(to: home, duration: 0.28)
            slide.timingMode = .easeOut
            let settle = SKAction.scaleX(to: 1, duration: 0.28)
            settle.timingMode = .easeOut
            letter.run(.sequence([.wait(forDuration: delay), .group([.fadeIn(withDuration: 0.14), slide, settle])]))
        }

        // Shine across the title (cropped to the letters)
        let crop = SKCropNode()
        let mask = SKNode()
        x = -pad * 0.6
        for glyph in glyphs {
            let piece = SKSpriteNode(texture: glyph.texture)
            piece.size = glyph.texture.size()
            piece.position = CGPoint(x: x + glyph.advance / 2, y: 4)
            x += glyph.advance
            mask.addChild(piece)
        }
        crop.maskNode = mask
        let sheen = SKSpriteNode(texture: CarArt.sheenTexture)
        sheen.size = CGSize(width: 60, height: 130)
        sheen.zRotation = -0.35
        sheen.blendMode = .add
        sheen.alpha = 0.9
        sheen.position = CGPoint(x: -80, y: 0)
        crop.addChild(sheen)
        group.addChild(crop)
        let lettersDone = 0.12 + Double(glyphs.count) * 0.04 + 0.3
        let sweep = SKAction.moveTo(x: total + 80, duration: 0.55)
        sweep.timingMode = .easeInEaseOut
        sheen.run(.sequence([.wait(forDuration: lettersDone), sweep, .removeFromParent()]))

        // An accent rule under the title, drawn out to its width as the letters land
        let rule = SKSpriteNode(color: accent, size: CGSize(width: max(60, total * 0.92), height: 4))
        rule.anchorPoint = CGPoint(x: 0, y: 0.5)
        rule.position = CGPoint(x: 4, y: -40)
        rule.xScale = 0.001
        group.addChild(rule)
        let draw = SKAction.scaleX(to: 1, duration: 0.45)
        draw.timingMode = .easeOut
        rule.run(.sequence([.wait(forDuration: lettersDone - 0.2), draw]))

        // Stats: one glass panel, label over value, hairline dividers
        let panelTexture = CarArt.finishStats(stats, accent: accent)
        let panel = SKSpriteNode(texture: panelTexture)
        panel.size = panelTexture.size()
        panel.anchorPoint = CGPoint(x: 0, y: 1)
        let panelHome = CGPoint(x: 4, y: -54)
        panel.position = CGPoint(x: panelHome.x, y: panelHome.y - 16)
        panel.alpha = 0
        group.addChild(panel)
        let rise = SKAction.move(to: panelHome, duration: 0.4)
        rise.timingMode = .easeOut
        panel.run(.sequence([.wait(forDuration: lettersDone + 0.05), .group([.fadeIn(withDuration: 0.3), rise])]))

        // Golden sparks drifting up behind the title
        for index in 0..<22 {
            let spark = SKSpriteNode(texture: dotTexture)
            let s = CGFloat.random(in: 3...6)
            spark.size = CGSize(width: s, height: s)
            spark.color = index % 3 == 0 ? .white : accent
            spark.colorBlendFactor = 1
            spark.blendMode = .add
            spark.alpha = 0
            spark.position = CGPoint(x: CGFloat.random(in: 0...max(40, total)), y: CGFloat.random(in: -60 ... 0))
            spark.zPosition = -1
            group.addChild(spark)
            let up = SKAction.moveBy(x: CGFloat.random(in: -16...16), y: CGFloat.random(in: 60...130), duration: 1.6)
            up.timingMode = .easeOut
            spark.run(.sequence([.wait(forDuration: 0.3 + Double.random(in: 0...1.2)),
                                 .group([.sequence([.fadeAlpha(to: 0.85, duration: 0.25), .wait(forDuration: 0.7), .fadeOut(withDuration: 0.65)]),
                                         up]),
                                 .removeFromParent()]))
        }

        // Ease out together, sliding left
        let out = SKAction.group([.fadeOut(withDuration: 0.4), .moveBy(x: -30, y: 0, duration: 0.4)])
        out.timingMode = .easeIn
        group.run(.sequence([.wait(forDuration: hold + 0.2), out, .removeFromParent()]))
        scrim.run(.sequence([.wait(forDuration: hold + 0.3), .fadeOut(withDuration: 0.4), .removeFromParent()]))
    }

    /// Parking levels: a parking ticket springs in from the lower left, a green rubber stamp
    /// slams PARKED onto it (thud, haptic, flecks of ink), the stars are punched in one by one
    /// and a red NEW BEST stamp follows a record; then the ticket slides away to the results.
    private func playParkedSequence() {
        finishAnimating = true
        // A clean frame: no status text over it, controls and HUD fade away
        statusLabel.text = ""
        challengeCard.removeAllActions()
        challengeCard.alpha = 0
        controlsLayer.run(.fadeAlpha(to: 0, duration: 0.25))
        hud.run(.fadeAlpha(to: 0, duration: 0.25))
        let layer = SKNode()
        layer.zPosition = 300
        addChild(layer)
        // Santim Ölçer measures the bay, then the same results screen as every other mode
        var hold = 0.5
        if let precision = lastPrecision {
            playInspection(precision, in: layer)
            hold = 2.2
        }
        layer.run(.sequence([.wait(forDuration: hold + 0.3), .fadeOut(withDuration: 0.2), .removeFromParent()]))
        run(.wait(forDuration: hold)) { [weak self] in
            guard let self = self else { return }
            self.finishAnimating = false
            self.checkLevelDone()
        }
    }

    /// Santim Ölçer: the bay lights up, a laser sweeps it end to end, measuring lines run from
    /// the car's sides to the bay lines with the gaps in centimetres, the angle comes up at the
    /// nose, and a dial counts up to the precision score and lands its grade (S = flawless).
    private func playInspection(_ precision: ParkPrecision, in layer: SKNode) {
        guard let world = world else { return }
        let spot = level.spots[slot]
        let u = CGVector(dx: cos(spot.angle), dy: sin(spot.angle))
        let v = CGVector(dx: -sin(spot.angle), dy: cos(spot.angle))
        func bay(_ a: CGFloat, _ b: CGFloat) -> CGPoint {           // along, across from the bay centre
            CGPoint(x: spot.center.x + u.dx * a + v.dx * b, y: spot.center.y + u.dy * a + v.dy * b)
        }
        let halfLength = spot.size.width / 2, halfWidth = spot.size.height / 2
        let screen = { (p: CGPoint) in world.project(p, height: 0.05) }
        let node = SKNode()
        node.zPosition = 5
        layer.addChild(node)
        let cyan = UIColor(red: 0.3, green: 0.9, blue: 1, alpha: 1)
        let laser = UIColor(red: 1, green: 0.22, blue: 0.3, alpha: 1)

        // Kicker
        let kicker = SKLabelNode()
        kicker.attributedText = NSAttributedString(string: Strings.precisionCheck, attributes: [
            .font: UIFont.ui(11, .heavy), .foregroundColor: cyan, .kern: 3])
        kicker.position = CGPoint(x: size.width / 2, y: size.height - max(insets.top, 12) - 28)
        kicker.alpha = 0
        node.addChild(kicker)
        kicker.run(.fadeIn(withDuration: 0.2))

        // The bay outline lights up
        let bayCorners = [bay(-halfLength, -halfWidth), bay(halfLength, -halfWidth), bay(halfLength, halfWidth), bay(-halfLength, halfWidth)]
        func outlinePath() -> CGPath {
            let corners = bayCorners.map(screen)
            let path = CGMutablePath()
            path.addLines(between: corners + [corners[0]])
            return path
        }
        let bayNode = SKShapeNode(path: outlinePath())
        bayNode.strokeColor = cyan
        bayNode.lineWidth = 2.5
        bayNode.blendMode = .add
        bayNode.alpha = 0
        node.addChild(bayNode)
        bayNode.run(.sequence([.fadeAlpha(to: 1, duration: 0.15), .fadeAlpha(to: 0.6, duration: 0.3)]))

        // The laser sweeps the bay, end to end
        let scan = SKShapeNode()
        scan.strokeColor = laser
        scan.lineWidth = 3
        scan.blendMode = .add
        node.addChild(scan)
        scan.run(.sequence([
            .customAction(withDuration: 0.6) { node, t in
                let a = -halfLength + 2 * halfLength * min(1, t / 0.6)
                let path = CGMutablePath()
                path.move(to: screen(bay(a, -halfWidth - 3)))
                path.addLine(to: screen(bay(a, halfWidth + 3)))
                (node as? SKShapeNode)?.path = path
            },
            .fadeOut(withDuration: 0.15), .removeFromParent(),
        ]))
        audio.play("whoosh", volume: 0.4)

        // Everything pinned to the road is laid out again every frame
        var followers: [(CGFloat) -> Void] = [{ _ in bayNode.path = outlinePath() }]
        // Measuring lines: from each side of the car to its bay line, with the gap
        let carU = CGVector(dx: cos(heading), dy: sin(heading))
        let carV = CGVector(dx: -sin(heading), dy: cos(heading))
        let carHalfWidth = Levels.carSize.height / 2
        let carAlong = (carPosition.x - spot.center.x) * u.dx + (carPosition.y - spot.center.y) * u.dy
        let sides: [(CGFloat, Int, String)] = [(1, precision.leftGap, Strings.gapLeft), (-1, precision.rightGap, Strings.gapRight)]
        for (index, side) in sides.enumerated() {
            let from = CGPoint(x: carPosition.x + carV.dx * carHalfWidth * side.0, y: carPosition.y + carV.dy * carHalfWidth * side.0)
            let to = bay(carAlong, halfWidth * side.0)
            let line = SKShapeNode()
            line.strokeColor = cyan
            line.lineWidth = 2
            line.blendMode = .add
            node.addChild(line)
            let at = 0.7 + Double(index) * 0.22
            let tag = measureTag(side.2, "\(max(0, side.1)) cm", color: cyan)
            // Drawn out from the car to the line, then kept on it every frame (the camera may
            // still be settling); the tag sits past the line's end so it never covers the car
            let drawStart = at
            func place(_ elapsed: CGFloat) {
                let a = screen(from), b = screen(to)
                let k = max(0, min(1, (Double(elapsed) - drawStart) / 0.18))
                let path = CGMutablePath()
                path.move(to: a)
                path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * CGFloat(k), y: a.y + (b.y - a.y) * CGFloat(k)))
                line.path = path
                let out = CGVector(dx: b.x - a.x, dy: b.y - a.y)
                let length = max(1, hypot(out.dx, out.dy))
                tag.position = CGPoint(x: b.x + out.dx / length * 34, y: b.y + out.dy / length * 18 + 4)
            }
            followers.append(place)
            tag.alpha = 0
            tag.setScale(0.6)
            node.addChild(tag)
            tag.run(.sequence([.wait(forDuration: at + 0.15), .group([.fadeIn(withDuration: 0.12), .scale(to: 1, duration: 0.15)])]))
            run(.wait(forDuration: at + 0.15)) { [weak self] in
                self?.audio.play("click", volume: 0.6)
                self?.tickHaptic.impactOccurred()
            }
        }
        // The angle at the nose
        let nosePoint = CGPoint(x: carPosition.x + carU.dx * Levels.carSize.width * 0.75, y: carPosition.y + carU.dy * Levels.carSize.width * 0.75)
        let angleTag = measureTag(Strings.angleShort, String(format: "%.1f°", precision.angle), color: cyan)
        followers.append { _ in
            let nose = screen(nosePoint)
            angleTag.position = CGPoint(x: nose.x, y: nose.y + 26)
        }
        angleTag.alpha = 0
        angleTag.setScale(0.6)
        node.addChild(angleTag)
        angleTag.run(.sequence([.wait(forDuration: 1.12), .group([.fadeIn(withDuration: 0.12), .scale(to: 1, duration: 0.15)])]))
        run(.wait(forDuration: 1.12)) { [weak self] in
            self?.audio.play("click", volume: 0.6)
            self?.tickHaptic.impactOccurred()
        }

        // The dial counts up to the score, then the grade lands
        let dial = SKNode()
        dial.position = CGPoint(x: size.width - max(insets.right, 12) - 92, y: size.height * 0.6)
        dial.alpha = 0
        node.addChild(dial)
        let back = SKShapeNode(circleOfRadius: 46)
        back.fillColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 0.85)
        back.strokeColor = UIColor(white: 1, alpha: 0.12)
        back.lineWidth = 6
        dial.addChild(back)
        let grade = precision.grade
        let gold = UIColor(red: 1, green: 0.74, blue: 0.1, alpha: 1)
        let ringColor = grade == .s ? gold : (grade == .a ? UIColor(red: 0.35, green: 0.95, blue: 0.6, alpha: 1) : cyan)
        let ring = SKShapeNode()
        ring.strokeColor = ringColor
        ring.lineWidth = 6
        ring.lineCap = .round
        dial.addChild(ring)
        let percent = SKLabelNode()
        percent.verticalAlignmentMode = .center
        percent.position = CGPoint(x: 0, y: 4)
        dial.addChild(percent)
        let caption = SKLabelNode()
        caption.attributedText = NSAttributedString(string: Strings.upper(Strings.precision), attributes: [
            .font: UIFont.ui(8, .heavy), .foregroundColor: UIColor(white: 1, alpha: 0.6), .kern: 1.4])
        caption.verticalAlignmentMode = .center
        caption.position = CGPoint(x: 0, y: -17)
        dial.addChild(caption)
        func setScore(_ value: Int) {
            percent.attributedText = NSAttributedString(string: "\(value)", attributes: [
                .font: UIFont.ui(26, .heavy).tabular, .foregroundColor: UIColor.white])
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: 46, startAngle: .pi / 2, endAngle: .pi / 2 - CGFloat(value) / 100 * .pi * 2, clockwise: true)
            ring.path = path
        }
        setScore(0)
        dial.run(.sequence([.wait(forDuration: 0.2), .fadeIn(withDuration: 0.2)]))
        var shown = -1
        dial.run(.sequence([.wait(forDuration: 0.4), .customAction(withDuration: 1.0) { _, t in
            let k = min(1, t / 1.0)
            let eased = 1 - pow(1 - k, 3)
            let value = Int((Double(precision.score) * Double(eased)).rounded())
            if value != shown { shown = value; setScore(value) }
        }]))
        // The grade slams onto the dial
        let letter = SKLabelNode()
        letter.attributedText = NSAttributedString(string: grade.rawValue, attributes: [
            .font: CarArt.raceFont(40), .foregroundColor: grade == .s ? gold : UIColor.white])
        letter.verticalAlignmentMode = .center
        letter.position = CGPoint(x: -64, y: 34)
        letter.alpha = 0
        letter.setScale(2.4)
        dial.addChild(letter)
        let title = SKLabelNode()
        title.attributedText = NSAttributedString(string: Strings.gradeTitle(grade.rawValue), attributes: [
            .font: CarArt.raceFont(17), .foregroundColor: grade == .s ? gold : UIColor.white, .kern: 0.6])
        title.horizontalAlignmentMode = .right
        title.verticalAlignmentMode = .center
        title.position = CGPoint(x: 46, y: -64)
        title.alpha = 0
        dial.addChild(title)
        let land = SKAction.group([.scale(to: 1, duration: 0.12), .fadeIn(withDuration: 0.08)])
        land.timingMode = .easeIn
        letter.run(.sequence([.wait(forDuration: 1.45), land]))
        title.run(.sequence([.wait(forDuration: 1.55), .fadeIn(withDuration: 0.2)]))
        run(.wait(forDuration: 1.55)) { [weak self] in
            guard let self = self else { return }
            self.audio.play(grade == .s ? "nitro" : "bump", volume: 0.8)
            if grade == .s {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // A burst of gold round the dial
                for _ in 0..<18 {
                    let spark = SKSpriteNode(texture: self.dotTexture)
                    let r = CGFloat.random(in: 3...6)
                    spark.size = CGSize(width: r, height: r)
                    spark.color = gold
                    spark.colorBlendFactor = 1
                    spark.blendMode = .add
                    dial.addChild(spark)
                    let angle = CGFloat.random(in: 0 ... .pi * 2)
                    let fly = SKAction.moveBy(x: cos(angle) * 90, y: sin(angle) * 90, duration: 0.5)
                    fly.timingMode = .easeOut
                    spark.run(.sequence([.group([fly, .fadeOut(withDuration: 0.5)]), .removeFromParent()]))
                }
            } else {
                self.bumpHaptic.impactOccurred(intensity: 0.7)
            }
        }
        let pinned = followers
        node.run(.customAction(withDuration: 2.3) { _, elapsed in pinned.forEach { $0(elapsed) } })
        // Out together as the ticket comes
        node.run(.sequence([.wait(forDuration: 2.05), .fadeOut(withDuration: 0.25), .removeFromParent()]))
    }

    /// A small measurement tag: a label and its value on a dark capsule with a coloured edge.
    private func measureTag(_ label: String, _ value: String, color: UIColor) -> SKNode {
        let tag = SKNode()
        let text = SKLabelNode()
        let string = NSMutableAttributedString(string: label + "  ", attributes: [
            .font: UIFont.ui(9, .heavy), .foregroundColor: color, .kern: 1.2])
        string.append(NSAttributedString(string: value, attributes: [
            .font: UIFont.ui(14, .heavy).tabular, .foregroundColor: UIColor.white]))
        text.attributedText = string
        text.verticalAlignmentMode = .center
        let width = text.frame.width + 20
        let pill = SKShapeNode(rect: CGRect(x: -width / 2, y: -12, width: width, height: 24), cornerRadius: 12)
        pill.fillColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 0.85)
        pill.strokeColor = color.withAlphaComponent(0.8)
        pill.lineWidth = 1.2
        tag.addChild(pill)
        tag.addChild(text)
        return tag
    }

    /// The parking ticket, stamped (see `playParkedSequence`).
    private func showParkTicket(in layer: SKNode) {
        // Soft shade on the left so the ticket stands off the scene
        let shade = SKSpriteNode(texture: CarArt.glowParticle().cgImage.map { SKTexture(cgImage: $0) })
        shade.color = .black
        shade.colorBlendFactor = 1
        shade.size = CGSize(width: size.width * 1.1, height: size.height * 1.5)
        shade.position = CGPoint(x: size.width * 0.18, y: size.height * 0.45)
        shade.alpha = 0
        layer.addChild(shade)
        shade.run(.fadeAlpha(to: 0.55, duration: 0.3))

        let paper = CGSize(width: 340, height: 190)
        let stubWidth: CGFloat = 62
        let ticket = SKNode()
        let target = CGPoint(x: max(insets.left + 24, 20) + paper.width / 2 + 20, y: size.height * 0.48)
        ticket.position = CGPoint(x: target.x - 60, y: -paper.height)
        ticket.zRotation = -0.42
        layer.addChild(ticket)
        let base = SKSpriteNode(texture: CarArt.parkTicket(size: paper, stub: stubWidth))
        base.size = CGSize(width: paper.width + 32, height: paper.height + 32)
        ticket.addChild(base)
        let top = paper.height / 2, left = -paper.width / 2, right = paper.width / 2
        // Thermal print: near-black ink, a red for the serial number
        let ink = UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
        let grey = UIColor(red: 0.45, green: 0.46, blue: 0.5, alpha: 1)
        let red = UIColor(red: 0.78, green: 0.16, blue: 0.18, alpha: 1)
        func text(_ string: String, _ font: UIFont, _ color: UIColor, kern: CGFloat = 0, at point: CGPoint,
                  align: SKLabelHorizontalAlignmentMode = .left, rotate: CGFloat = 0) {
            let label = SKLabelNode()
            label.attributedText = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
            label.horizontalAlignmentMode = align
            label.verticalAlignmentMode = .center
            label.position = point
            label.zRotation = rotate
            ticket.addChild(label)
        }
        let main = left + stubWidth
        // Header beside the P sign: the garage (the level) and its number
        text(level.name, CarArt.raceFont(20, italic: false), ink, at: CGPoint(x: main + 62, y: top - 40))
        text(Levels.title(levelIndex, online: onlineMatch), UIFont.ui(11, .semibold), grey,
             at: CGPoint(x: main + 62, y: top - 57))
        // Printed lines: entry and exit times from the clock, then the round's figures
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let now = Date()
        var rows: [(String, String)] = [(Strings.ticketIn, clock.string(from: now.addingTimeInterval(-max(1, localTime)))),
                                        (Strings.ticketOut, clock.string(from: now)),
                                        (Strings.statTime, String(format: "%.1f s", localTime)),
                                        (Strings.statCrashes, "\(hits)")]
        if let precision = lastPrecision { rows.append((Strings.precision, Strings.percent(precision.score))) }
        let mono = UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let monoBold = UIFont.monospacedSystemFont(ofSize: 12, weight: .heavy)
        for (index, row) in rows.enumerated() {
            let y = top - 85 - CGFloat(index) * 17
            text(Strings.upper(row.0), mono, grey, at: CGPoint(x: main + 14, y: y))
            text(row.1, index >= 2 ? monoBold : mono, ink, at: CGPoint(x: main + 104, y: y))
        }
        // Stub: the name down its length and a serial number in red
        text("PARKRIFT", UIFont.ui(8, .heavy), grey, kern: 1.6,
             at: CGPoint(x: left + stubWidth / 2, y: top - 140), align: .center, rotate: .pi / 2)
        text(String(format: "№ %05d", 1000 + (levelIndex * 7919 + Int(localTime * 10)) % 89_000),
             .monospacedSystemFont(ofSize: 8, weight: .bold), red, at: CGPoint(x: left + stubWidth / 2, y: -top + 9), align: .center)
        // The precision grade, top right (gold for an S)
        if let precision = lastPrecision {
            let grade = precision.grade
            let gold = UIColor(red: 1, green: 0.74, blue: 0.1, alpha: 1)
            let disc = SKShapeNode(circleOfRadius: 16)
            disc.fillColor = grade == .s ? gold : ink
            disc.strokeColor = .clear
            disc.position = CGPoint(x: right - 28, y: top - 44)
            ticket.addChild(disc)
            let letter = SKLabelNode()
            letter.attributedText = NSAttributedString(string: grade.rawValue, attributes: [
                .font: CarArt.raceFont(21), .foregroundColor: grade == .s ? ink : UIColor.white])
            letter.verticalAlignmentMode = .center
            letter.position = disc.position
            ticket.addChild(letter)
        }
        // Stars: punched into the stub's marks after the stamp (solo levels only)
        var stars: [SKSpriteNode] = []
        let earned = isCity ? 0 : AppModel.stars(forHits: hits)
        if !isCity {
            for index in 0..<earned {
                let star = makeIcon("star.fill", size: 17, color: UIColor(red: 1, green: 0.74, blue: 0.1, alpha: 1))
                star.position = CGPoint(x: left + stubWidth / 2, y: top - 44 - CGFloat(index) * 26)
                star.setScale(0)
                ticket.addChild(star)
                stars.append(star)
            }
        }

        // In: sweeps up from below and settles at a slight tilt
        let rise = SKAction.move(to: target, duration: 0.42)
        rise.timingMode = .easeOut
        let tilt = SKAction.rotate(toAngle: -0.05, duration: 0.42)
        tilt.timingMode = .easeOut
        ticket.run(.sequence([.group([rise, tilt]), .rotate(toAngle: -0.075, duration: 0.12), .rotate(toAngle: -0.06, duration: 0.1)]))

        // The stamp lands over the right of the ticket
        let stamp = SKSpriteNode(texture: CarArt.stamp(Strings.upper(Strings.parkedBig.replacingOccurrences(of: "!", with: "")),
                                                       color: UIColor(red: 0.08, green: 0.6, blue: 0.32, alpha: 1), fontSize: 17))
        // Low on the right, over the QR code: clear of the printed figures
        stamp.position = CGPoint(x: right - 66, y: -top + 36)
        stamp.zRotation = -0.22
        stamp.alpha = 0
        stamp.setScale(2.6)
        ticket.addChild(stamp)
        let slam = SKAction.group([.scale(to: 0.94, duration: 0.11), .fadeAlpha(to: 0.92, duration: 0.08)])
        slam.timingMode = .easeIn
        stamp.run(.sequence([.wait(forDuration: 0.5), slam, .scale(to: 1.0, duration: 0.08)]))
        run(.wait(forDuration: 0.61)) { [weak self] in
            guard let self = self else { return }
            self.audio.play("bump", volume: 0.9)
            self.bumpHaptic.impactOccurred(intensity: 1)
            // The ticket gives under the blow
            ticket.run(.sequence([.scale(to: 0.965, duration: 0.05), .scale(to: 1.0, duration: 0.12)]))
            // Flecks of ink
            for _ in 0..<10 {
                let fleck = SKSpriteNode(texture: self.dotTexture)
                let r = CGFloat.random(in: 2...4.5)
                fleck.size = CGSize(width: r, height: r)
                fleck.color = UIColor(red: 0.08, green: 0.6, blue: 0.32, alpha: 1)
                fleck.colorBlendFactor = 1
                fleck.position = stamp.position
                ticket.addChild(fleck)
                let angle = CGFloat.random(in: 0 ... .pi * 2)
                let reach = CGFloat.random(in: 70...120)
                let fly = SKAction.moveBy(x: cos(angle) * reach, y: sin(angle) * reach * 0.6, duration: 0.25)
                fly.timingMode = .easeOut
                fleck.run(.sequence([fly, .wait(forDuration: 0.6), .fadeOut(withDuration: 0.3)]))
            }
        }
        // Stars punched in
        for (index, star) in stars.enumerated() {
            let at = 0.95 + Double(index) * 0.2
            star.run(.sequence([.wait(forDuration: at), .scale(to: 1.35, duration: 0.1), .scale(to: 1.0, duration: 0.1)]))
            run(.wait(forDuration: at)) { [weak self] in
                self?.tickHaptic.impactOccurred()
                self?.audio.play("click", volume: 0.7)
            }
        }
        // A record: printed in red after the time, as the printer adds a line
        var hold = 2.1 + Double(stars.count) * 0.12
        if newBest {
            let best = SKLabelNode()
            best.attributedText = NSAttributedString(string: "★ " + Strings.upper(Strings.newBestShort), attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .heavy), .foregroundColor: UIColor(red: 0.78, green: 0.16, blue: 0.18, alpha: 1)])
            best.horizontalAlignmentMode = .left
            best.verticalAlignmentMode = .center
            // On its own line under the figures, clear of the stamp
            best.position = CGPoint(x: left + stubWidth + 14, y: -top + 18)
            best.alpha = 0
            best.setScale(1.6)
            ticket.addChild(best)
            let at = 1.05 + Double(stars.count) * 0.2
            best.run(.sequence([.wait(forDuration: at), .group([.fadeIn(withDuration: 0.08), .scale(to: 1, duration: 0.12)])]))
            run(.wait(forDuration: at)) { [weak self] in
                self?.audio.play("click", volume: 0.8)
                self?.tickHaptic.impactOccurred()
            }
            hold += 0.3
        }
        // Out: drops away, then the results
        let away = SKAction.group([.moveBy(x: -40, y: -size.height * 0.7, duration: 0.35), .rotate(byAngle: 0.25, duration: 0.35),
                                   .fadeOut(withDuration: 0.3)])
        away.timingMode = .easeIn
        ticket.run(.sequence([.wait(forDuration: hold), away]))
        shade.run(.sequence([.wait(forDuration: hold + 0.1), .fadeOut(withDuration: 0.3)]))
        layer.run(.sequence([.wait(forDuration: hold + 0.5), .removeFromParent()]))
        run(.wait(forDuration: hold + 0.3)) { [weak self] in
            guard let self = self else { return }
            self.finishAnimating = false
            self.checkLevelDone()
        }
    }

    private func finishShotB(layer: SKNode) {
        // A white flash covers the cut to the orbit
        let flash = SKSpriteNode(color: .white, size: CGSize(width: size.width + 40, height: size.height + 40))
        flash.position = CGPoint(x: size.width / 2, y: size.height / 2)
        flash.zPosition = -4
        flash.alpha = 0.85
        flash.blendMode = .add
        layer.addChild(flash)
        flash.run(.sequence([.fadeOut(withDuration: 0.35), .removeFromParent()]))
        world?.celebrate()
        audio.play("park", volume: 0.9)
        bumpHaptic.impactOccurred(intensity: 1.0)
    }

    private func confetti(at point: CGPoint) {
        guard let screen = world?.project(point, height: 1.5) else { return }
        let colors: [UIColor] = [CarArt.playerColors[0], CarArt.playerColors[1],
                                 UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1), UIColor(red: 0.4, green: 1, blue: 0.6, alpha: 1)]
        for index in 0..<28 {
            let piece = SKSpriteNode(color: colors[index % colors.count], size: CGSize(width: 7, height: 4))
            piece.position = screen
            piece.zRotation = CGFloat.random(in: 0...CGFloat.pi)
            fxLayer.addChild(piece)
            let angle = CGFloat(index) / 28 * 2 * CGFloat.pi + CGFloat.random(in: -0.2...0.2)
            let distance = CGFloat.random(in: 50...110)
            piece.run(.sequence([
                .group([.moveBy(x: cos(angle) * distance, y: sin(angle) * distance + 20, duration: 0.8),
                        .rotate(byAngle: CGFloat.random(in: -6...6), duration: 0.8),
                        .sequence([.wait(forDuration: 0.5), .fadeOut(withDuration: 0.3)])]),
                .removeFromParent()
            ]))
        }
    }

    // MARK: Level flow

    private func checkLevelDone() {
        guard localParked, !resultsShown, !finishAnimating else { return }
        let together = online && friendPresent
        if together && !remoteParked {
            statusLabel.text = Strings.waitingFriendPark
            return
        }
        resultsShown = true
        statusLabel.text = ""

        // The round goes to whoever finished first; the match ends once someone has two
        if together { countRound() }
        let footer: ResultFooter
        if onlineMatch ? matchOver : Levels.isLast(levelIndex) {
            footer = .final
        } else if together {
            footer = .autoNext(seconds: advanceDelay)
            if isHost { scheduleAdvance() }
        } else {
            footer = .solo(hasNext: true)
        }
        showResults(footer: footer)
    }

    /// Who took this round: the first to finish (the lower time); someone who did not finish
    /// loses to someone who did; neither finishing, or the very same time, gives no point.
    private func roundWinners() -> (me: Bool, friend: Bool) {
        let mine: Double? = localTime >= 0 ? localTime : nil
        let theirs: Double? = remoteParked && remoteTime >= 0 ? remoteTime : nil
        switch (mine, theirs) {
        case let (m?, f?): return (m < f, f < m)
        case (.some, nil): return (true, false)
        case (nil, .some): return (false, true)
        default: return (false, false)
        }
    }

    private func countRound() {
        guard !roundCounted else { return }
        roundCounted = true
        let result = roundWinners()
        if result.me { myWins += 1 }
        if result.friend { friendWins += 1 }
    }

    private func scheduleAdvance() {
        guard !advanceScheduled else { return }
        advanceScheduled = true
        run(.wait(forDuration: advanceDelay)) { [weak self] in
            guard let self = self else { return }
            let next = self.levelIndex + 1
            if self.online && self.friendPresent {
                self.model?.send(["t": "lvl", "n": next])
            }
            self.loadBehindCurtain(level: next)
        }
    }

    private func showResults(footer: ResultFooter) {
        let myTime: Double? = localTime >= 0 ? localTime : nil
        var entries = [ResultEntry(name: Strings.you, slot: slot, time: myTime, hits: hits, isMe: true, isWinner: false)]
        var headline: String?
        var scoreLine: String?
        var roundLine: String?
        var outcome: ResultOutcome = myTime == nil ? .failed : .success
        if (online && friendPresent) || remoteParked {
            let friendTime: Double? = remoteParked && remoteTime >= 0 ? remoteTime : nil
            entries.append(ResultEntry(name: Strings.friend, slot: otherSlot, time: friendTime,
                                       hits: remoteHits, isMe: false, isWinner: false))
            // Head to head: the first to finish takes the round (a crash costs time on the road, no
            // penalty on top)
            let result = roundWinners()
            entries[0].isWinner = result.me
            entries[1].isWinner = result.friend
            let iWon = result.me
            let friendWon = result.friend
            countRound()
            headline = iWon ? Strings.youWon : (friendWon ? Strings.friendWon : Strings.draw)
            outcome = iWon ? .won : (friendWon ? .lost : .draw)
            if isCity {
                scoreLine = Strings.score(myWins, friendWins)
                if case .final = footer, onlineMatch {
                    // The match decides the card; the last round is a line of its own (winning the
                    // match after failing the last round used to show a red "you won")
                    headline = myWins > friendWins ? Strings.youWon : (friendWins > myWins ? Strings.friendWon : Strings.draw)
                    outcome = myWins > friendWins ? .champion : (friendWins > myWins ? .lost : .draw)
                    roundLine = myTime == nil ? Strings.lastRoundFailed
                        : (iWon ? Strings.lastRoundWon : (friendWon ? Strings.lastRoundLost : Strings.lastRoundDraw))
                }
            }
            refreshLevelLabel()
        } else if case .final = footer, isCity {
            headline = Strings.allRounds
            if myTime != nil { outcome = .champion }
        }
        if let reason = failReason, headline == nil { headline = reason }
        if level.race && entries.count == 1 {
            entries[0].score = myTime.map { Levels.raceScore(time: $0, crashes: hits) } ?? -1
            if !level.racers.isEmpty, myTime != nil, let place = racePlace {
                if headline == nil { headline = Strings.racePlaceHeadline(place) }
                scoreLine = Strings.racePlace(place, of: level.racers.count + 1)
                if place == 1 { outcome = .won }
            }
            if headline == nil { headline = Strings.finished }
        }
        // Taxi: the fare and the tip
        if level.taxi != nil {
            settleTaxi()
            if myTime != nil && headline == nil { headline = taxiTip > 0 ? Strings.customerHappy : Strings.customerDelivered }
        }
        // Coins for the round (and any daily task it completed)
        let me = entries[0]
        let headToHead = entries.count > 1
        let mode: RunStats.Mode = online ? .online : (level.race ? .race : (isCity ? .city : .park))
        let stats = RunStats(mode: mode, finished: me.time != nil, stars: me.stars,
                             won: headToHead ? (me.isWinner && !entries[1].isWinner) : nil,
                             race: level.race, solo: !isCity, hits: hits, driftPoints: runDriftPoints,
                             nearMisses: runNearMisses, escapes: runEscapes, topSpeed: runTopSpeed,
                             precision: me.time != nil ? lastPrecision?.score : nil,
                             fare: taxiFare, tip: taxiTip,
                             place: level.race && !level.racers.isEmpty && myTime != nil ? racePlace : nil)
        let reward = model?.finishRun(stats)
        model?.results = ResultsInfo(levelIndex: levelIndex, levelTitle: Levels.title(levelIndex, online: onlineMatch) + " · " + level.name,
                                     entries: entries, footer: footer, newBest: newBest,
                                     bestTime: isCity ? nil : model?.bestTime(for: levelIndex),
                                     headline: headline, scoreLine: scoreLine, reward: reward,
                                     outcome: outcome, roundLine: roundLine,
                                     precision: me.time != nil && (!isCity || level.taxi != nil) && !level.race ? lastPrecision?.score : nil)
        // The results own the screen: the pedals and the HUD step aside (back on the next load).
        // At once, not faded: the frame freezes just below and would keep a half-faded HUD
        controlsLayer.removeAllActions()
        hud.removeAllActions()
        controlsLayer.alpha = 0
        hud.alpha = 0
        // The card covers the world: stop drawing it (a frozen frame) until the next level loads
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self, self.model?.results != nil else { return }
            self.worldFrozen = true
            self.world?.setRenderingPaused(true)
        }
    }

    // MARK: Pedestrians

    private var pedestrians: PedestrianSystem?
    private var pedestrianNodes: [SCNNode] = []
    private var pendingHorn: CGPoint?

    // MARK: Spectating

    private func showSpectateOverlay() {
        world?.resetSpectate()
        // Seen this close from every side: the body is drawn from both sides so no panel ever
        // shows the street through it
        remoteCar?.setDoubleSided()
        spectateLast = nil
        let overlay = SKNode()
        overlay.zPosition = 250
        let barHeight = size.height * 0.085
        for top in [true, false] {
            let bar = SKSpriteNode(color: .black, size: CGSize(width: size.width + 40, height: barHeight))
            bar.anchorPoint = CGPoint(x: 0.5, y: top ? 0 : 1)
            let edge = top ? size.height : 0
            bar.position = CGPoint(x: size.width / 2, y: edge)
            overlay.addChild(bar)
            let slide = SKAction.moveTo(y: top ? edge - barHeight : barHeight, duration: 0.4)
            slide.timingMode = .easeOut
            bar.run(slide)
        }
        // "LIVE · watching your rival" tag, top left inside the bar
        let tag = SKNode()
        tag.position = CGPoint(x: max(30, size.width * 0.05), y: size.height - barHeight / 2)
        let dot = SKShapeNode(circleOfRadius: 4)
        dot.fillColor = UIColor(red: 1, green: 0.22, blue: 0.25, alpha: 1)
        dot.strokeColor = .clear
        dot.run(.repeatForever(.sequence([.fadeAlpha(to: 0.25, duration: 0.6), .fadeAlpha(to: 1, duration: 0.6)])))
        tag.addChild(dot)
        let live = SKLabelNode(text: Strings.liveTag)
        live.fontName = "Barlow-ExtraBold"
        live.fontSize = 12
        live.fontColor = .white
        live.horizontalAlignmentMode = .left
        live.verticalAlignmentMode = .center
        live.position = CGPoint(x: 12, y: 0)
        tag.addChild(live)
        let what = SKLabelNode(text: Strings.spectatingFriend.localUpper)
        what.fontName = "Barlow-SemiBold"
        what.fontSize = 12
        what.fontColor = UIColor.white.withAlphaComponent(0.7)
        what.horizontalAlignmentMode = .left
        what.verticalAlignmentMode = .center
        what.position = CGPoint(x: 22 + live.frame.width, y: 0)
        tag.addChild(what)
        tag.alpha = 0
        tag.run(.sequence([.wait(forDuration: 0.3), .fadeIn(withDuration: 0.3)]))
        overlay.addChild(tag)
        // Cut dip
        let dip = SKSpriteNode(color: .black, size: CGSize(width: size.width + 40, height: size.height + 40))
        dip.position = CGPoint(x: size.width / 2, y: size.height / 2)
        dip.alpha = 0
        dip.name = "dip"
        dip.zPosition = -1
        overlay.addChild(dip)
        addChild(overlay)
        spectateOverlay = overlay
        controlsLayer.run(.fadeAlpha(to: 0, duration: 0.3))
    }

    private func spectateCut() {
        guard let dip = spectateOverlay?.childNode(withName: "dip") else { return }
        dip.removeAllActions()
        dip.alpha = 0.55
        dip.run(.fadeOut(withDuration: 0.22))
    }

    private func hideSpectateOverlay() {
        spectateOverlay?.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        spectateOverlay = nil
        world?.endSpectate()
        controlsLayer.run(.fadeAlpha(to: 1, duration: 0.3))
        hud.run(.fadeAlpha(to: 1, duration: 0.3))
    }

    /// Each person's state last frame and when it began (for the clips that play once).
    private var pedestrianStates: [PedestrianSystem.State] = []
    private var pedestrianSince: [TimeInterval] = []

    private func updatePedestrianNodes() {
        guard let people = pedestrians else { return }
        if pedestrianStates.count != people.people.count {
            pedestrianStates = people.people.map { $0.state }
            pedestrianSince = Array(repeating: lastUpdate, count: people.people.count)
        }
        // People are detailed meshes: draw the ones within 40 m, the light mesh past 14 m from
        // the camera
        let range: CGFloat = 400
        let eye = world?.cameraNode.simdWorldPosition ?? SIMD3<Float>(0, 0, 0)
        for (index, person) in people.people.enumerated() where index < pedestrianNodes.count {
            let node = pedestrianNodes[index]
            if pedestrianStates[index] != person.state {
                pedestrianStates[index] = person.state
                pedestrianSince[index] = lastUpdate
            }
            let outOfRange = abs(person.position.x - carPosition.x) > range || abs(person.position.y - carPosition.y) > range
            if node.isHidden != outOfRange { node.isHidden = outOfRange }
            if outOfRange { continue }
            let character = person.outfit
            let since = CGFloat(lastUpdate - pedestrianSince[index])
            let spot = World3D.vec(person.position)
            let far = simd_distance(eye, SIMD3<Float>(spot.x, spot.y, spot.z)) > 14
            // Only the people close by cast a shadow
            if node.castsShadow == far { node.castsShadow = !far }
            let geometry: SCNGeometry?
            switch person.state {
            case .walking, .crossing:
                // Hurrying people run; the clip follows the distance walked so the feet stick
                if person.hurry > 1.3 {
                    geometry = PedestrianModels.geometry(character: character, clip: .run, phase: person.stride / PedestrianModels.runCycle, far: far)
                } else {
                    geometry = PedestrianModels.geometry(character: character, clip: .walk, phase: person.stride / PedestrianModels.walkCycle, far: far)
                }
            case .waiting, .browsing:
                // Some check their phone while they wait; each starts at its own point of the clip
                let clip: PedestrianModels.Clip = index % 3 == 0 ? .phone : .idle
                geometry = PedestrianModels.geometry(character: character, clip: clip, time: since + CGFloat(index) * 0.37, far: far)
            case .startled:
                geometry = PedestrianModels.geometry(character: character, clip: .dodge, time: since, far: far)
            case .fallen:
                geometry = PedestrianModels.geometry(character: character, clip: .knockdown, time: since, far: far)
            case .angry:
                geometry = PedestrianModels.geometry(character: character, clip: .angry, time: since, far: far)
            }
            if let geometry = geometry, node.geometry !== geometry { node.geometry = geometry }
            var p = World3D.vec(person.position)
            p.y = Float(level.city?.kerbHeight(at: person.position) ?? 0)
            node.position = p
            node.eulerAngles = SCNVector3(0, Float(person.heading), 0)
        }
    }

    // MARK: Nitro pickups and speed cameras

    private struct Pickup {
        let point: CGPoint
        let node: SCNNode
        var readyAt: TimeInterval
    }

    private struct SpeedCamera {
        let point: CGPoint
        let alongX: Bool
        let flash: SCNNode
        var readyAt: TimeInterval
    }

    private var pickups: [Pickup] = []
    private var speedCameras: [SpeedCamera] = []
    private var bonusLabel = SKLabelNode()
    private let cameraThreshold: CGFloat = 45   // km/h
    private let policeThreshold: CGFloat = 70   // km/h

    /// Canisters on the lanes of a dozen street segments and speed cameras on a few others
    /// (same layout for both players: seeded by the level).
    private func setupBonuses() {
        pickups.removeAll()
        speedCameras.removeAll()
        if bonusLabel.parent == nil {
            bonusLabel = makeLabel(Strings.nitroPickup, size: 20, color: UIColor(red: 0.45, green: 0.9, blue: 1.0, alpha: 1))
            bonusLabel.position = CGPoint(x: size.width / 2, y: size.height * 0.7)
            bonusLabel.zPosition = 21
            bonusLabel.alpha = 0.002
            hud.addChild(bonusLabel)
        }
        if policeBanner.parent == nil { setupPoliceWarning() }
        guard let city = level.city, let world = world else { return }
        var segments: [(mid: CGPoint, alongX: Bool)] = []
        for y in city.ys {
            for i in 0..<(city.cols - 1) { segments.append((CGPoint(x: (city.xs[i] + city.xs[i + 1]) / 2, y: y), true)) }
        }
        for x in city.xs {
            for j in 0..<(city.rows - 1) { segments.append((CGPoint(x: x, y: (city.ys[j] + city.ys[j + 1]) / 2), false)) }
        }
        var rng = SplitMix64(seed: UInt64(levelIndex) &* 104_729 &+ 17)
        segments.shuffle(using: &rng)
        for segment in segments.prefix(12) {
            let lane: CGFloat = rng.unit() < 0.5 ? CityMap.laneOffset : -CityMap.laneOffset
            let shift = rng.range(-120, 120)
            let point = segment.alongX ? CGPoint(x: segment.mid.x + shift, y: segment.mid.y + lane)
                                       : CGPoint(x: segment.mid.x + lane, y: segment.mid.y + shift)
            pickups.append(Pickup(point: point, node: world.addNitroPickup(at: point), readyAt: 0))
        }
        for segment in segments.dropFirst(12).prefix(4) {
            let pole = segment.alongX ? CGPoint(x: segment.mid.x + 60, y: segment.mid.y + 106)
                                      : CGPoint(x: segment.mid.x + 106, y: segment.mid.y + 60)
            speedCameras.append(SpeedCamera(point: segment.mid, alongX: segment.alongX,
                                            flash: world.addSpeedCamera(at: pole, lookingAlongX: segment.alongX), readyAt: 0))
        }
    }

    private func updateBonuses() {
        guard phase == .driving, !localParked, !pickups.isEmpty || !speedCameras.isEmpty else { return }
        let now = lastUpdate
        for index in pickups.indices where now >= pickups[index].readyAt {
            let pickup = pickups[index]
            if !pickup.node.isHidden, pickup.point.distance(to: carPosition) < 26 {
                pickups[index].readyAt = now + 18
                pickup.node.runAction(.sequence([.group([.scale(to: 1.8, duration: 0.15), .fadeOut(duration: 0.15)]), .hide()]))
                nitro = min(1, nitro + 0.5)
                if benchmark { FrameMonitor.shared.mark("pickup") }
                audio.play("beep", volume: 0.7)
                tickHaptic.impactOccurred(intensity: 0.8)
                flashBonus(Strings.nitroPickup)
            } else if pickup.node.isHidden && pickups[index].readyAt > 0 {
                // Back after the cooldown
                pickup.node.scale = SCNVector3(1, 1, 1)
                pickup.node.isHidden = false
                pickup.node.runAction(.fadeIn(duration: 0.4))
                pickups[index].readyAt = 0
            }
        }
        let kmh = abs(velocity) * 0.36
        for index in speedCameras.indices where now >= speedCameras[index].readyAt {
            let camera = speedCameras[index]
            let along = camera.alongX ? abs(carPosition.x - camera.point.x) : abs(carPosition.y - camera.point.y)
            let across = camera.alongX ? abs(carPosition.y - camera.point.y) : abs(carPosition.x - camera.point.x)
            guard along < 40, across < CityMap.roadHalf, kmh > 12 else { continue }
            speedCameras[index].readyAt = now + 8
            if benchmark { FrameMonitor.shared.mark("radar") }
            camera.flash.removeAllActions()
            camera.flash.scale = SCNVector3(1, 1, 1)
            camera.flash.runAction(.sequence([.wait(duration: 0.12), .scale(to: 0.001, duration: 0.2)]))
            let speedText = "\(Int(kmh.rounded())) km/h"
            if kmh >= policeThreshold {
                dispatchPolice(Strings.crimeSpeeding(speedText))
            }
            if kmh >= cameraThreshold {
                nitro = min(1, nitro + 0.35)
                audio.play("beep", volume: 0.8)
                notifyHaptic.notificationOccurred(.success)
                flashBonus(Strings.radarBonus(speedText))
            } else {
                flashBonus(Strings.radarSlow(speedText, Int(cameraThreshold)))
            }
        }
    }

    /// Short text pop above the car (prebuilt label, so the first bonus does not stall).
    private func flashBonus(_ text: String) {
        // The count's GO stands where bonus lines show: a bonus (the radar right after the start)
        // clears it at once instead of printing over it
        if !countdownNode.isHidden && countdownNode.alpha > 0.01 {
            countdownNode.removeAllActions()
            countdownNode.run(.sequence([.fadeOut(withDuration: 0.08), .hide()]), withKey: "leave")
        }
        bonusLabel.removeAllActions()
        bonusLabel.text = text
        bonusLabel.position = policeWarningShown ? CGPoint(x: size.width / 2 + 40, y: hudTop - 126)
                                                 : CGPoint(x: size.width / 2, y: size.height * 0.7)
        bonusLabel.setScale(0.6)
        bonusLabel.alpha = 1
        bonusLabel.run(.sequence([.scale(to: 1.1, duration: 0.12), .scale(to: 1.0, duration: 0.08), .wait(forDuration: 0.9),
                                  .group([.fadeAlpha(to: 0.002, duration: 0.3), .moveBy(x: 0, y: 16, duration: 0.3)])]))
    }

    private func showToast(_ text: String) {
        let toast = makeLabel(text, size: 16, color: UIColor(red: 1, green: 0.7, blue: 0.6, alpha: 1))
        toast.position = CGPoint(x: size.width / 2, y: size.height / 2 + 70)
        toast.zPosition = 10
        hud.addChild(toast)
        toast.run(.sequence([.wait(forDuration: 2.0), .fadeOut(withDuration: 0.4), .removeFromParent()]))
    }
}

/// Rigid-body helpers for car crashes (both cars about the same weight).
enum CarPhysics {
    /// Fastest turn a crash may give a car (rad/s).
    static let maxSpin: CGFloat = 2.4

    /// The turn a change of velocity `change` gives a car when the blow comes from `from`: the
    /// blow lands on the car's outline nearest that point, and its lever about the car's middle
    /// over the car's turning inertia (a box the size of a car) gives the turn rate.
    static func spin(from change: CGVector, at from: CGPoint, carCenter: CGPoint, carHeading: CGFloat) -> CGFloat {
        let half = CGSize(width: Levels.carSize.width / 2, height: Levels.carSize.height / 2)
        // The point of the outline nearest the other car, in the car's own frame
        let rx = from.x - carCenter.x, ry = from.y - carCenter.y
        let c = cos(carHeading), s = sin(carHeading)
        var lx = rx * c + ry * s, ly = -rx * s + ry * c
        lx = max(-half.width, min(half.width, lx))
        ly = max(-half.height, min(half.height, ly))
        let px = lx * c - ly * s, py = lx * s + ly * c
        // Turning inertia of a box per unit mass: (L² + W²) / 12
        let size = Levels.carSize
        let inertia = (size.width * size.width + size.height * size.height) / 12
        let torque = px * change.dy - py * change.dx
        // Four loaded tyres resist the turn: only part of the lever's turn gets through
        let tyreHold: CGFloat = 0.25
        return max(-maxSpin, min(maxSpin, torque / inertia * tyreHold))
    }
}
