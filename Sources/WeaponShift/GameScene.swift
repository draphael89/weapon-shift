import AppKit
import AVFoundation
import GameController
import SpriteKit

private let gameSize = CGSize(width: 480, height: 270)
private let gravity: CGFloat = -940
private let reportEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()
private let launchArguments = CommandLine.arguments
private let playtestReportArgument = argumentValue(after: "--playtest-report")
private let playtestSnapshotArgument = argumentValue(after: "--playtest-snapshot")
private let snapshotModeArgument = argumentValue(after: "--snapshot")

enum GameScreen {
    case title
    case running
    case dead
    case victory
}

enum Weapon: CaseIterable {
    case broadsword
    case daggers
    case chainWhip

    var label: String {
        switch self {
        case .broadsword: "Broadsword"
        case .daggers: "Daggers"
        case .chainWhip: "Chain-whip"
        }
    }

    var runSpeed: CGFloat {
        switch self {
        case .broadsword: 86
        case .daggers: 126
        case .chainWhip: 104
        }
    }

    var groundAcceleration: CGFloat {
        switch self {
        case .broadsword: 390
        case .daggers: 760
        case .chainWhip: 540
        }
    }

    var airAcceleration: CGFloat {
        switch self {
        case .broadsword: 230
        case .daggers: 440
        case .chainWhip: 340
        }
    }

    var dashCost: CGFloat {
        switch self {
        case .broadsword: 0.34
        case .daggers: 0.18
        case .chainWhip: 0.28
        }
    }

    var dashSpeed: CGFloat {
        switch self {
        case .broadsword: 206
        case .daggers: 292
        case .chainWhip: 244
        }
    }

    var playerTextureName: String {
        switch self {
        case .broadsword: "BroadswordPlayerSprite"
        case .daggers: "DaggerPlayerSprite"
        case .chainWhip: "ChainPlayerSprite"
        }
    }

    var playerSpriteSize: CGSize {
        switch self {
        case .broadsword: CGSize(width: 63, height: 51)
        case .daggers: CGSize(width: 66, height: 40)
        case .chainWhip: CGSize(width: 62, height: 41)
        }
    }
}

enum InputAction: Hashable {
    case left
    case right
    case up
    case down
    case jump
    case dash
    case attack
    case switchWeapon
    case restart
    case slot1
    case slot2
    case slot3
}

private enum EnemyKind {
    case skeleton
    case archer
    case exploder
    case boss

    var cost: Int {
        switch self {
        case .skeleton: 1
        case .archer: 2
        case .exploder: 2
        case .boss: 12
        }
    }

    var visualScale: CGFloat {
        switch self {
        case .skeleton: 1.14
        case .archer: 1.14
        case .exploder: 1.16
        case .boss: 1.06
        }
    }

    var textureName: String {
        switch self {
        case .skeleton: "SkeletonSprite"
        case .archer: "ArcherSprite"
        case .exploder: "ExploderSprite"
        case .boss: "BossSprite"
        }
    }

    var spriteSize: CGSize {
        switch self {
        case .skeleton: CGSize(width: 31, height: 37)
        case .archer: CGSize(width: 34, height: 30)
        case .exploder: CGSize(width: 33, height: 38)
        case .boss: CGSize(width: 78, height: 65)
        }
    }
}

private enum Door: Hashable {
    case left
    case right
    case top
    case bottom
}

private enum AttackKind {
    case broadsword
    case dagger(step: Int)
    case whip(target: UUID?)
}

private struct Attack {
    var kind: AttackKind
    var age: CGFloat = 0
    var duration: CGFloat
    var hitIDs = Set<UUID>()
    var movementCredited = false
}

struct InputState {
    var keyboardSources = [String: Set<InputAction>]()
    var gamepadDown = Set<InputAction>()
    var pressed = Set<InputAction>()

    var keyboardDown: Set<InputAction> {
        keyboardSources.values.reduce(into: Set<InputAction>()) { result, actions in
            result.formUnion(actions)
        }
    }

    func held(_ action: InputAction) -> Bool {
        keyboardDown.contains(action) || gamepadDown.contains(action)
    }

    func wasPressed(_ action: InputAction) -> Bool {
        pressed.contains(action)
    }

    mutating func setKeyboard(_ action: InputAction, isDown: Bool) {
        setKeyboard(action, source: "\(action)", isDown: isDown)
    }

    mutating func setKeyboard(_ action: InputAction, source: String, isDown: Bool) {
        if isDown {
            if !held(action) {
                pressed.insert(action)
            }
            var actions = keyboardSources[source, default: []]
            actions.insert(action)
            keyboardSources[source] = actions
        } else {
            guard var actions = keyboardSources[source] else { return }
            actions.remove(action)
            if actions.isEmpty {
                keyboardSources.removeValue(forKey: source)
            } else {
                keyboardSources[source] = actions
            }
        }
    }

    mutating func setGamepad(_ action: InputAction, isDown: Bool) {
        if isDown {
            if !gamepadDown.contains(action) {
                pressed.insert(action)
            }
            gamepadDown.insert(action)
        } else {
            gamepadDown.remove(action)
        }
    }

    mutating func clearGamepad() {
        gamepadDown.removeAll()
    }

    mutating func endFrame() {
        pressed.removeAll()
    }

}

private struct RoomTemplate {
    let name: String
    let doors: Set<Door>
    let tier: Int
    let budget: Int
    let platforms: [CGRect]
    let spawns: [CGPoint]
}

private struct EnemySeed {
    let kind: EnemyKind
    let position: CGPoint
}

private struct RunRoom {
    let template: RoomTemplate
    let isBoss: Bool
    let seeds: [EnemySeed]
    var cleared = false
}

private struct PlaytestReport: Encodable {
    let score: Int
    let result: String
    let roomsCleared: Int
    let enemiesDefeated: Int
    let enemiesRemaining: Int
    let currentRoomIndex: Int
    let playerX: Double
    let playerY: Double
    let weaponsUsed: [String]
    let hpRemaining: Int
    let damageTaken: Int
    let dashCount: Int
    let jumpCount: Int
    let attackCount: Int
    let weaponMovement: WeaponMovementReport
    let playtestSnapshot: String?
    let bossReached: Bool
    let victory: Bool
    let seconds: Double
    let notes: [String]
}

private struct WeaponMovementReport: Encodable {
    let broadswordRootSeconds: Double
    let broadswordGuardHits: Int
    let daggerLungeEvents: Int
    let daggerLungeHits: Int
    let daggerDashCancels: Int
    let chainAnchorPullEvents: Int
    let chainPullEvents: Int
}

private struct PlaytestState {
    var elapsed: CGFloat = 0
    var enemiesDefeated = 0
    var roomsCleared = 0
    var weaponsUsed = Set<Weapon>()
    var bossReached = false
    var lastRoomIndex = 0
    var lastEnemyCount = 0
    var finished = false
    var jumpTap = false
    var attackTap = false
    var dashTap = false
    var switchTap = false
    var damageTaken = 0
    var dashCount = 0
    var jumpCount = 0
    var attackCount = 0
    var broadswordRootSeconds: CGFloat = 0
    var broadswordGuardHits = 0
    var daggerLungeEvents = 0
    var daggerLungeHits = 0
    var daggerDashCancels = 0
    var chainAnchorPullEvents = 0
    var chainPullEvents = 0
}

@MainActor
private final class Enemy {
    let id = UUID()
    let kind: EnemyKind
    let maxHP: Int
    var hp: Int
    var position: CGPoint
    var velocity = CGVector.zero
    var facing: CGFloat = -1
    var cooldown: CGFloat = 0
    var windup: CGFloat = 0
    var fuse: CGFloat = 0
    var phase = 1
    let node: SKSpriteNode
    let alertNode: SKLabelNode

    init(kind: EnemyKind, position: CGPoint) {
        self.kind = kind
        self.position = position
        maxHP = switch kind {
        case .skeleton: 4
        case .archer: 3
        case .exploder: 2
        case .boss: 42
        }
        hp = maxHP

        let fallbackSize = switch kind {
        case .skeleton: CGSize(width: 15, height: 23)
        case .archer: CGSize(width: 15, height: 21)
        case .exploder: CGSize(width: 16, height: 16)
        case .boss: CGSize(width: 42, height: 48)
        }
        if let texture = SpriteArt.texture(named: kind.textureName) {
            node = SKSpriteNode(texture: texture, color: .clear, size: kind.spriteSize)
        } else {
            node = SKSpriteNode(color: .clear, size: fallbackSize)
            decorateEnemyNode(node, kind: kind, size: fallbackSize)
        }
        node.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.lightingBitMask = 1
        alertNode = SKLabelNode(fontNamed: "Menlo-Bold")
        alertNode.text = "!"
        alertNode.fontSize = 11
        alertNode.fontColor = rgb(252, 224, 99)
        alertNode.position = CGPoint(x: 0, y: node.size.height + 6)
        alertNode.isHidden = true
        node.addChild(alertNode)
        syncNode()
    }

    var frame: CGRect {
        CGRect(x: position.x - node.size.width / 2, y: position.y, width: node.size.width, height: node.size.height)
    }

    func syncNode() {
        node.position = CGPoint(x: round(position.x), y: round(position.y))
        node.xScale = (facing < 0 ? -1 : 1) * kind.visualScale
        node.yScale = kind.visualScale
        node.zPosition = kind == .boss ? 245 : 235
    }
}

@MainActor
private final class Projectile {
    let node: SKSpriteNode
    var velocity: CGVector
    let damage: Int

    init(position: CGPoint, velocity: CGVector, damage: Int, color: SKColor, textureName: String? = nil, size: CGSize = CGSize(width: 7, height: 3)) {
        self.velocity = velocity
        self.damage = damage
        if let textureName, let texture = SpriteArt.texture(named: textureName) {
            node = SKSpriteNode(texture: texture, color: .clear, size: size)
        } else {
            node = SKSpriteNode(color: color, size: size)
        }
        node.position = position
        node.lightingBitMask = 1
    }

    var frame: CGRect {
        CGRect(x: node.position.x - 3.5, y: node.position.y - 1.5, width: 7, height: 3)
    }
}

@MainActor
final class DungeonScene: SKScene {
    weak var shell: GameStore?

    var reduceShake = false
    var highContrastHUD = false

    private let backgroundLayer = SKNode()
    private let worldLayer = SKNode()
    private let effectsLayer = SKNode()
    private let hudLayer = SKNode()
    private let sound = ToneSynth()

    private var input = InputState()
    private var lastTime: TimeInterval = 0
    private var screen: GameScreen = .title
    private var rooms = [RunRoom]()
    private var currentRoomIndex = 0
    private var roomCleared = false
    private var chestNode: SKSpriteNode?

    private var playerNode = SKSpriteNode(color: rgb(77, 114, 157), size: CGSize(width: 12, height: 20))
    private var playerLight = SKLightNode()
    private var playerPosition = CGPoint(x: 44, y: 42)
    private var playerVelocity = CGVector.zero
    private var facing: CGFloat = 1
    private var hp = 4
    private var stamina: CGFloat = 1
    private var souls = 0
    private var weapon: Weapon = .broadsword
    private var onGround = false
    private var canDoubleJump = true
    private var touchingWall: CGFloat = 0
    private var dashTimer: CGFloat = 0
    private var invulnerableTimer: CGFloat = 0
    private var parryTimer: CGFloat = 0
    private var coyoteTimer: CGFloat = 0
    private var jumpBufferTimer: CGFloat = 0
    private var attackBufferTimer: CGFloat = 0
    private var rootTimer: CGFloat = 0
    private var daggerStep = 0
    private var comboWindow: CGFloat = 0
    private var afterimageTimer: CGFloat = 0
    private var activeAttack: Attack?
    private var whipLine: SKNode?
    private var whipAnchorTarget: CGPoint?
    private var whipAnchors = [CGPoint]()
    private var currentPlayerTextureName: String?

    private var enemies = [Enemy]()
    private var projectiles = [Projectile]()
    private var platforms = [CGRect]()
    private var parallaxLayers = [SKNode]()

    private var hitStop: CGFloat = 0
    private var shake: CGFloat = 0
    private var hudRefreshTimer: CGFloat = 0
    private var playtest: PlaytestState?
    private var manualPlaytestClock = false
    private var manualPlaytestTick = false
    private let isPlaytestRun = ProcessInfo.processInfo.environment["WEAPONSHIFT_PLAYTEST"] == "1" || launchArguments.contains("--playtest")
    private var isDeterministicRun: Bool {
        isPlaytestRun || snapshotModeArgument != nil
    }

    override func didMove(to view: SKView) {
        backgroundColor = .black
        anchorPoint = .zero
        scaleMode = .fill

        addChild(backgroundLayer)
        addChild(worldLayer)
        addChild(effectsLayer)
        addChild(hudLayer)
        effectsLayer.zPosition = 700
        hudLayer.zPosition = 1000

        configurePlayerNode()
        buildFloor()
        renderTitle()
        if let snapshotModeArgument {
            prepareSnapshot(mode: snapshotModeArgument)
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    func startAutomatedPlaytest() {
        guard playtest == nil else { return }
        lastTime = 0
        playtest = PlaytestState()
        restartRun()
        startManualPlaytestClock()
    }

    func setShellPaused(_ paused: Bool) {
        isPaused = paused
    }

    func restartRun() {
        isPaused = false
        screen = .running
        hp = 4
        stamina = 1
        souls = 0
        weapon = .broadsword
        playerPosition = CGPoint(x: 38, y: 42)
        playerVelocity = .zero
        activeAttack = nil
        input = InputState()
        onGround = false
        canDoubleJump = true
        touchingWall = 0
        dashTimer = 0
        invulnerableTimer = 0
        parryTimer = 0
        coyoteTimer = 0
        jumpBufferTimer = 0
        attackBufferTimer = 0
        rootTimer = 0
        hitStop = 0
        shake = 0
        comboWindow = 0
        daggerStep = 0
        currentRoomIndex = 0
        buildFloor()
        loadRoom(at: 0)
    }

    func prepareSnapshot(mode: String) {
        isPaused = false
        input = InputState()

        switch mode.lowercased() {
        case "title":
            screen = .title
            renderTitle()
        case "boss":
            restartRun()
            loadRoom(at: max(0, rooms.count - 1))
            weapon = .broadsword
            hp = 3
            stamina = 0.64
            souls = 997
            playerPosition = CGPoint(x: 164, y: 86)
            playerVelocity = CGVector(dx: 0, dy: 0)
            facing = 1
            activeAttack = Attack(kind: .broadsword, duration: 0.32)
            spawnSlash(color: rgb(252, 207, 96), width: 58, height: 26, yOffset: 18)
            spawnPixels(count: 44, at: CGPoint(x: 290, y: 82), color: rgb(230, 72, 78), power: 92)
            spawnDamageNumber(42, at: CGPoint(x: 302, y: 112), color: rgb(252, 207, 96))
            syncPlayerNode()
            updateHUD()
        default:
            restartRun()
            if rooms.indices.contains(1) {
                loadRoom(at: 1)
            }
            weapon = .chainWhip
            hp = 4
            stamina = 0.78
            souls = 1247
            playerPosition = CGPoint(x: 188, y: 86)
            playerVelocity = CGVector(dx: 120, dy: 46)
            facing = 1
            dashTimer = 0.16
            syncPlayerNode()
            addSnapshotAfterimages()

            let target = enemies.max { $0.position.y < $1.position.y }
            target?.alertNode.isHidden = false
            renderWhip(to: target?.position)
            spawnTelegraph(from: CGPoint(x: 420, y: 42), to: playerPosition)
            spawnSlash(color: rgb(250, 190, 76), width: 42, height: 18, yOffset: 17)
            let hitPoint = (target?.position ?? CGPoint(x: 316, y: 90)) + CGPoint(x: 0, y: 14)
            spawnPixels(count: 36, at: hitPoint, color: rgb(247, 183, 73), power: 100)
            spawnDamageNumber(17, at: hitPoint + CGPoint(x: 0, y: 16), color: rgb(252, 211, 92))
            activeAttack = Attack(kind: .whip(target: target?.id), duration: 0.3)
            updateHUD()
        }

        isPaused = true
    }

    func handleKey(_ event: NSEvent, isDown: Bool) {
        if isDown, !event.isARepeat, isPauseEvent(event) {
            DispatchQueue.main.async { self.shell?.togglePause() }
            return
        }

        for action in mappedActions(for: event) {
            input.setKeyboard(action, source: "key-\(event.keyCode)-\(action)", isDown: isDown)
        }
    }

    func handleFlags(_ flags: NSEvent.ModifierFlags) {
        input.setKeyboard(.dash, source: "modifier-shift", isDown: flags.intersection(.deviceIndependentFlagsMask).contains(.shift))
    }

    override func update(_ currentTime: TimeInterval) {
        if isPlaytestRun, manualPlaytestClock, !manualPlaytestTick {
            return
        }

        let dt = lastTime == 0 ? CGFloat(1.0 / 60.0) : min(CGFloat(currentTime - lastTime), CGFloat(1.0 / 30.0))
        lastTime = currentTime
        pollGamepad()
        drivePlaytest(dt)

        switch screen {
        case .title:
            if input.wasPressed(.attack) || input.wasPressed(.jump) || input.wasPressed(.restart) {
                restartRun()
            }
            input.endFrame()
            return
        case .dead, .victory:
            if screen == .dead {
                finishPlaytest(result: "death")
            }
            if input.wasPressed(.restart) || input.wasPressed(.attack) || input.wasPressed(.jump) {
                restartRun()
            }
            input.endFrame()
            return
        case .running:
            break
        }

        if hitStop > 0 {
            hitStop = max(0, hitStop - dt)
            input.endFrame()
            return
        }

        updateTimers(dt)
        updatePlayer(dt)
        updateAttack(dt)
        updateEnemies(dt)
        updateProjectiles(dt)
        updateChest()
        updateRoomProgress()
        updateCameraFeel(dt)
        syncPlayerNode()
        updateParallax()
        hudRefreshTimer -= dt
        if hudRefreshTimer <= 0 {
            hudRefreshTimer = 0.12
            updateHUD()
        }
        input.endFrame()
    }

    private func startManualPlaytestClock() {
        manualPlaytestClock = true
        var tick = 0

        func step() {
            guard self.playtest?.finished == false else { return }
            tick += 1
            self.manualPlaytestTick = true
            self.update(TimeInterval(tick) / 60)
            self.manualPlaytestTick = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
                step()
            }
        }

        DispatchQueue.main.async {
            step()
        }
    }

    private func configurePlayerNode() {
        if let texture = SpriteArt.texture(named: weapon.playerTextureName) {
            playerNode = SKSpriteNode(texture: texture, color: .clear, size: weapon.playerSpriteSize)
            playerNode.anchorPoint = CGPoint(x: 0.5, y: 0.08)
            playerNode.zPosition = 280
            playerNode.lightingBitMask = 1
            currentPlayerTextureName = weapon.playerTextureName
            configurePlayerLight()
            return
        }

        playerNode = SKSpriteNode(color: .clear, size: CGSize(width: 17, height: 24))
        playerNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        playerNode.zPosition = 280
        playerNode.lightingBitMask = 1

        addPixel(to: playerNode, color: rgb(17, 19, 30), rect: CGRect(x: -7, y: 17, width: 14, height: 7), z: 2)
        addPixel(to: playerNode, color: rgb(9, 12, 21), rect: CGRect(x: -5, y: 19, width: 10, height: 4), z: 3)
        addPixel(to: playerNode, color: rgb(115, 239, 235), rect: CGRect(x: 2, y: 20, width: 2, height: 1), z: 5)
        addPixel(to: playerNode, color: rgb(82, 24, 56), rect: CGRect(x: -10, y: 7, width: 5, height: 12), z: 1)
        addPixel(to: playerNode, color: rgb(115, 38, 75), rect: CGRect(x: -12, y: 4, width: 6, height: 6), z: 1)
        addPixel(to: playerNode, color: rgb(25, 34, 58), rect: CGRect(x: -6, y: 6, width: 6, height: 12), z: 2)
        addPixel(to: playerNode, color: rgb(36, 50, 82), rect: CGRect(x: 0, y: 5, width: 7, height: 13), z: 2)
        addPixel(to: playerNode, color: rgb(108, 226, 230), rect: CGRect(x: -8, y: 3, width: 2, height: 18), z: 5)
        addPixel(to: playerNode, color: rgb(95, 203, 216), rect: CGRect(x: 6, y: 6, width: 2, height: 11), z: 5)
        addPixel(to: playerNode, color: rgb(230, 176, 75), rect: CGRect(x: -5, y: 10, width: 11, height: 2), z: 4)
        addPixel(to: playerNode, color: rgb(157, 107, 52), rect: CGRect(x: 5, y: 8, width: 5, height: 2), z: 4)
        addPixel(to: playerNode, color: rgb(13, 14, 19), rect: CGRect(x: -6, y: 0, width: 5, height: 4), z: 3)
        addPixel(to: playerNode, color: rgb(13, 14, 19), rect: CGRect(x: 2, y: 0, width: 6, height: 4), z: 3)
        addPixel(to: playerNode, color: rgb(197, 151, 77), rect: CGRect(x: 8, y: 12, width: 2, height: 8), z: 4)

        configurePlayerLight()
    }

    private func updatePlayerTexture() {
        guard currentPlayerTextureName != weapon.playerTextureName else { return }
        guard let texture = SpriteArt.texture(named: weapon.playerTextureName) else { return }
        playerNode.texture = texture
        playerNode.size = weapon.playerSpriteSize
        playerNode.anchorPoint = CGPoint(x: 0.5, y: 0.08)
        currentPlayerTextureName = weapon.playerTextureName
    }

    private func configurePlayerLight() {
        playerLight = SKLightNode()
        playerLight.categoryBitMask = 1
        playerLight.lightColor = rgb(89, 190, 218)
        playerLight.ambientColor = rgb(18, 16, 22, alpha: 0.35)
        playerLight.shadowColor = .clear
        playerLight.falloff = 2.1
        playerNode.addChild(playerLight)
    }

    private func buildFloor() {
        let templates = roomTemplates()
        var selected = [RunRoom]()
        let start = templates[0]
        selected.append(RunRoom(template: start, isBoss: false, seeds: seeds(for: start, roomIndex: 0)))

        let middle = templates.dropFirst().filter { $0.doors.contains(.left) && $0.doors.contains(.right) }
        let roomCount = isDeterministicRun ? 6 : Int.random(in: 6...8)
        for index in 1..<(roomCount - 1) {
            let tier = min(3, 1 + index / 2)
            let candidates = middle.filter { $0.tier <= tier + 1 }
            let template = isDeterministicRun ? middle[(index - 1) % middle.count] : (candidates.randomElement() ?? middle[index % middle.count])
            selected.append(RunRoom(template: template, isBoss: false, seeds: seeds(for: template, roomIndex: index)))
        }

        let bossTemplate = templates.last!
        selected.append(RunRoom(
            template: bossTemplate,
            isBoss: true,
            seeds: [EnemySeed(kind: .boss, position: CGPoint(x: 356, y: 52))]
        ))
        rooms = selected
    }

    private func loadRoom(at index: Int) {
        currentRoomIndex = index
        let room = rooms[index]
        roomCleared = room.cleared
        chestNode = nil
        enemies.removeAll()
        projectiles.removeAll()
        platforms = room.template.platforms
        activeAttack = nil
        whipLine?.removeFromParent()
        whipLine = nil
        whipAnchorTarget = nil
        whipAnchors = anchors(for: room.template.name)

        backgroundLayer.removeAllChildren()
        worldLayer.removeAllChildren()
        effectsLayer.removeAllChildren()
        hudLayer.removeAllChildren()
        parallaxLayers.removeAll()

        renderRoom(room.template, isBoss: room.isBoss)
        renderWhipAnchors()
        worldLayer.addChild(playerNode)
        for seed in room.seeds where !room.cleared {
            let enemy = Enemy(kind: seed.kind, position: seed.position)
            enemies.append(enemy)
            worldLayer.addChild(enemy.node)
        }
        if room.cleared, !room.isBoss {
            spawnChest(open: true)
        }
        syncPlayerNode()
        updateHUD()
        playtest?.lastRoomIndex = index
        playtest?.lastEnemyCount = enemies.count
    }

    private func renderTitle() {
        backgroundLayer.removeAllChildren()
        worldLayer.removeAllChildren()
        effectsLayer.removeAllChildren()
        hudLayer.removeAllChildren()
        parallaxLayers.removeAll()

        if addTitleBackdrop() {
            addSprite(to: hudLayer, color: rgb(2, 3, 4), rect: CGRect(x: 0, y: 259, width: 480, height: 11), z: 930)
        } else {
            renderRoom(roomTemplates()[2], isBoss: false)
            addPixelText("WEAPON SHIFT", at: CGPoint(x: 240, y: 158), scale: 5, color: rgb(246, 232, 177), align: .center)
            addPixelText("WEAPON = MOVEMENT", at: CGPoint(x: 240, y: 135), scale: 2, color: rgb(142, 203, 203), align: .center)
            addPixelText("J/X ATTACK   K/SHIFT DASH   TAB WEAPON", at: CGPoint(x: 240, y: 72), scale: 2, color: rgb(217, 212, 190), align: .center)
            addPixelText("PRESS ATTACK JUMP OR RETURN", at: CGPoint(x: 240, y: 53), scale: 2, color: rgb(249, 199, 98), align: .center)
        }
    }

    private func addTitleBackdrop() -> Bool {
        addBackdrop(named: "TitleAttract", to: backgroundLayer, z: -100)
    }

    private func addDungeonBackplate() -> Bool {
        addBackdrop(named: "DungeonBackplate", to: backgroundLayer, z: -100)
    }

    private func addBackdrop(named name: String, to layer: SKNode, z: CGFloat) -> Bool {
        guard let texture = SpriteArt.texture(named: name) else { return false }
        let backdrop = SKSpriteNode(texture: texture, size: gameSize)
        backdrop.anchorPoint = .zero
        backdrop.position = .zero
        backdrop.zPosition = z
        layer.addChild(backdrop)
        return true
    }

    private func renderRoom(_ template: RoomTemplate, isBoss: Bool) {
        let usesBackplate = addDungeonBackplate()
        if !usesBackplate {
            let paletteBase = isBoss ? rgb(40, 21, 31) : rgb(25, 30, 35)
            addSprite(to: backgroundLayer, color: paletteBase, rect: CGRect(origin: .zero, size: gameSize), z: -80)
            addSprite(to: backgroundLayer, color: isBoss ? rgb(72, 34, 55, alpha: 0.55) : rgb(40, 57, 63, alpha: 0.35), rect: CGRect(x: 0, y: 0, width: 480, height: 46), z: -70)

            for layerIndex in 0..<3 {
                let layer = SKNode()
                layer.zPosition = CGFloat(-60 + layerIndex * 8)
                backgroundLayer.addChild(layer)
                parallaxLayers.append(layer)
                let color = [
                    rgb(33, 43, 49),
                    rgb(39, 52, 55),
                    rgb(48, 60, 58)
                ][layerIndex]
                let yBase = CGFloat(46 + layerIndex * 23)
                for column in 0..<9 {
                    let height = CGFloat(deterministicInt(seed: layerIndex * 997 + column * 37, in: 28...88) + layerIndex * 12)
                    let rect = CGRect(x: CGFloat(column * 62) - 20, y: yBase, width: 42, height: height)
                    addRuinedColumn(to: layer, color: color, rect: rect)
                }
            }

            for x in stride(from: 0, through: 464, by: 16) {
                for y in stride(from: 0, through: 254, by: 16) where y < 32 || y > 222 || x == 0 || x == 464 {
                    addStoneTile(
                        at: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                        moss: deterministicInt(seed: x * 31 + y * 17, in: 0...5) == 0,
                        z: 0
                    )
                }
            }
        }

        for platform in template.platforms where !usesBackplate || platform.minY > 32 {
            addStonePlatform(platform)
        }

        if usesBackplate {
            addTorchGlow(at: CGPoint(x: 48, y: 172))
            addTorchGlow(at: CGPoint(x: 402, y: 172))
        } else if !isBoss {
            let torchPositions = [CGPoint(x: 66, y: 190), CGPoint(x: 240, y: 210), CGPoint(x: 410, y: 184)]
            for point in torchPositions {
                addTorch(at: point)
            }
            addSprite(to: worldLayer, color: rgb(92, 113, 72), rect: CGRect(x: 210, y: 35, width: 60, height: 5), z: 4)
            addExitDoor(at: CGPoint(x: 452, y: 44), open: false)
        } else {
            let torchPositions = [CGPoint(x: 66, y: 190), CGPoint(x: 240, y: 210), CGPoint(x: 410, y: 184)]
            for point in torchPositions {
                addTorch(at: point)
            }
            addBossDoor(at: CGPoint(x: 420, y: 44))
        }
        if !usesBackplate {
            addForegroundRubble(isBoss: isBoss)
        }
    }

    private func roomTemplates() -> [RoomTemplate] {
        [
            RoomTemplate(
                name: "Start Steps",
                doors: [.right],
                tier: 1,
                budget: 1,
                platforms: basePlatforms([
                    CGRect(x: 92, y: 78, width: 72, height: 8),
                    CGRect(x: 286, y: 96, width: 78, height: 8)
                ]),
                spawns: [CGPoint(x: 326, y: 42)]
            ),
            RoomTemplate(
                name: "Archer Shelf",
                doors: [.left, .right],
                tier: 1,
                budget: 4,
                platforms: basePlatforms([
                    CGRect(x: 82, y: 86, width: 82, height: 8),
                    CGRect(x: 296, y: 128, width: 94, height: 8)
                ]),
                spawns: [CGPoint(x: 124, y: 94), CGPoint(x: 334, y: 136), CGPoint(x: 390, y: 42)]
            ),
            RoomTemplate(
                name: "Low Bridge",
                doors: [.left, .right],
                tier: 1,
                budget: 3,
                platforms: basePlatforms([
                    CGRect(x: 122, y: 74, width: 236, height: 8),
                    CGRect(x: 195, y: 136, width: 90, height: 8)
                ]),
                spawns: [CGPoint(x: 160, y: 82), CGPoint(x: 250, y: 144), CGPoint(x: 360, y: 42)]
            ),
            RoomTemplate(
                name: "Broken Spine",
                doors: [.left, .right, .top],
                tier: 2,
                budget: 4,
                platforms: basePlatforms([
                    CGRect(x: 58, y: 86, width: 74, height: 8),
                    CGRect(x: 198, y: 122, width: 82, height: 8),
                    CGRect(x: 340, y: 92, width: 82, height: 8)
                ]),
                spawns: [CGPoint(x: 92, y: 94), CGPoint(x: 238, y: 130), CGPoint(x: 382, y: 100)]
            ),
            RoomTemplate(
                name: "Moss Shaft",
                doors: [.left, .right, .bottom],
                tier: 2,
                budget: 4,
                platforms: basePlatforms([
                    CGRect(x: 54, y: 116, width: 90, height: 8),
                    CGRect(x: 184, y: 74, width: 98, height: 8),
                    CGRect(x: 322, y: 146, width: 92, height: 8)
                ]),
                spawns: [CGPoint(x: 96, y: 124), CGPoint(x: 230, y: 82), CGPoint(x: 362, y: 154)]
            ),
            RoomTemplate(
                name: "Crush Hall",
                doors: [.left, .right],
                tier: 2,
                budget: 5,
                platforms: basePlatforms([
                    CGRect(x: 88, y: 65, width: 70, height: 8),
                    CGRect(x: 214, y: 92, width: 52, height: 8),
                    CGRect(x: 334, y: 65, width: 70, height: 8)
                ]),
                spawns: [CGPoint(x: 120, y: 73), CGPoint(x: 240, y: 100), CGPoint(x: 368, y: 73), CGPoint(x: 396, y: 42)]
            ),
            RoomTemplate(
                name: "Candle Teeth",
                doors: [.left, .right],
                tier: 2,
                budget: 4,
                platforms: basePlatforms([
                    CGRect(x: 116, y: 102, width: 58, height: 8),
                    CGRect(x: 226, y: 146, width: 62, height: 8),
                    CGRect(x: 342, y: 102, width: 58, height: 8)
                ]),
                spawns: [CGPoint(x: 145, y: 110), CGPoint(x: 257, y: 154), CGPoint(x: 370, y: 110)]
            ),
            RoomTemplate(
                name: "Hook Lesson",
                doors: [.left, .right],
                tier: 2,
                budget: 5,
                platforms: basePlatforms([
                    CGRect(x: 70, y: 82, width: 62, height: 8),
                    CGRect(x: 210, y: 154, width: 68, height: 8),
                    CGRect(x: 350, y: 82, width: 62, height: 8)
                ]),
                spawns: [CGPoint(x: 100, y: 90), CGPoint(x: 244, y: 162), CGPoint(x: 380, y: 90), CGPoint(x: 330, y: 42)]
            ),
            RoomTemplate(
                name: "Exploder Pit",
                doors: [.left, .right],
                tier: 3,
                budget: 5,
                platforms: basePlatforms([
                    CGRect(x: 48, y: 90, width: 94, height: 8),
                    CGRect(x: 190, y: 70, width: 110, height: 8),
                    CGRect(x: 346, y: 118, width: 86, height: 8)
                ]),
                spawns: [CGPoint(x: 95, y: 98), CGPoint(x: 245, y: 78), CGPoint(x: 388, y: 126), CGPoint(x: 410, y: 42)]
            ),
            RoomTemplate(
                name: "Blade Balcony",
                doors: [.left, .right, .top],
                tier: 3,
                budget: 6,
                platforms: basePlatforms([
                    CGRect(x: 74, y: 132, width: 90, height: 8),
                    CGRect(x: 204, y: 92, width: 76, height: 8),
                    CGRect(x: 324, y: 152, width: 92, height: 8)
                ]),
                spawns: [CGPoint(x: 118, y: 140), CGPoint(x: 242, y: 100), CGPoint(x: 370, y: 160), CGPoint(x: 360, y: 42)]
            ),
            RoomTemplate(
                name: "Last Antechamber",
                doors: [.left, .right],
                tier: 3,
                budget: 6,
                platforms: basePlatforms([
                    CGRect(x: 80, y: 82, width: 112, height: 8),
                    CGRect(x: 288, y: 82, width: 112, height: 8),
                    CGRect(x: 188, y: 146, width: 104, height: 8)
                ]),
                spawns: [CGPoint(x: 130, y: 90), CGPoint(x: 240, y: 154), CGPoint(x: 344, y: 90), CGPoint(x: 410, y: 42)]
            ),
            RoomTemplate(
                name: "Bone Monarch",
                doors: [.left],
                tier: 3,
                budget: 12,
                platforms: basePlatforms([
                    CGRect(x: 70, y: 92, width: 84, height: 8),
                    CGRect(x: 196, y: 144, width: 92, height: 8),
                    CGRect(x: 364, y: 150, width: 64, height: 8)
                ]),
                spawns: [CGPoint(x: 356, y: 42)]
            )
        ]
    }

    private func seeds(for template: RoomTemplate, roomIndex: Int) -> [EnemySeed] {
        var budget = template.budget + min(2, roomIndex / 3)
        var result = [EnemySeed]()
        let roster: [EnemyKind] = roomIndex < 2 ? [.skeleton, .archer] : [.skeleton, .archer, .exploder]
        let spawnPoints = isDeterministicRun ? template.spawns : template.spawns.shuffled()

        for (spawnIndex, point) in spawnPoints.enumerated() {
            let affordable = roster.filter { $0.cost <= budget }
            guard let kind = affordable.randomElement() else { break }
            let chosen = isDeterministicRun ? affordable[spawnIndex % affordable.count] : kind
            budget -= chosen.cost
            result.append(EnemySeed(kind: chosen, position: point))
        }
        return result.isEmpty ? [EnemySeed(kind: .skeleton, position: template.spawns.first ?? CGPoint(x: 340, y: 42))] : result
    }

    private func drivePlaytest(_ dt: CGFloat) {
        guard var state = playtest, !state.finished else { return }
        state.elapsed += dt
        if currentRoomIndex != state.lastRoomIndex {
            state.lastRoomIndex = currentRoomIndex
            state.lastEnemyCount = enemies.count
        }
        if rooms.indices.contains(currentRoomIndex), rooms[currentRoomIndex].isBoss {
            state.bossReached = true
        }
        if state.elapsed > 110 {
            playtest = state
            finishPlaytest(result: "timeout")
            return
        }

        if screen == .title {
            pressForPlaytest(.attack, tap: &state.attackTap)
            playtest = state
            return
        }
        guard screen == .running else {
            playtest = state
            return
        }

        if currentRoomIndex == 0, !state.weaponsUsed.contains(.broadsword) {
            input.setGamepad(.slot1, isDown: true)
            state.weaponsUsed.insert(.broadsword)
        } else {
            input.setGamepad(.slot1, isDown: false)
        }
        if currentRoomIndex == 1, !state.weaponsUsed.contains(.daggers) {
            input.setGamepad(.slot2, isDown: true)
            state.weaponsUsed.insert(.daggers)
        } else {
            input.setGamepad(.slot2, isDown: false)
        }
        if currentRoomIndex >= 2, !state.weaponsUsed.contains(.chainWhip) {
            input.setGamepad(.slot3, isDown: true)
            state.weaponsUsed.insert(.chainWhip)
        } else {
            input.setGamepad(.slot3, isDown: false)
        }

        if enemies.isEmpty {
            if currentRoomIndex == 2, state.chainAnchorPullEvents == 0, !whipAnchors.isEmpty {
                weapon = .chainWhip
                state.weaponsUsed.insert(.chainWhip)
                holdForPlaytest(.right, active: false)
                holdForPlaytest(.left, active: false)
                input.setGamepad(.attack, isDown: activeAttack == nil)
                playtest = state
                return
            }
            holdForPlaytest(.right, active: true)
            holdForPlaytest(.left, active: false)
            holdForPlaytest(.dash, active: playerPosition.x < 410 && stamina > 0.32)
            pressForPlaytest(.jump, active: onGround && playerPosition.x > 150 && playerPosition.x < 235, tap: &state.jumpTap)
            playtest = state
            return
        }

        let reachable = enemies.filter { abs($0.position.y - playerPosition.y) < 28 }
        let targetPool = reachable.isEmpty ? enemies : reachable
        let target = targetPool.min {
            distance($0.position, playerPosition) < distance($1.position, playerPosition)
        }
        guard let target else {
            playtest = state
            return
        }

        let dx = target.position.x - playerPosition.x
        let verticalDelta = target.position.y - playerPosition.y
        if currentRoomIndex == 0, state.broadswordRootSeconds < 0.4 {
            weapon = .broadsword
            state.weaponsUsed.insert(.broadsword)
        } else if currentRoomIndex == 1, state.daggerLungeEvents < 6 {
            weapon = .daggers
            state.weaponsUsed.insert(.daggers)
        } else if verticalDelta > 20, abs(dx) < 156 {
            input.setGamepad(.slot3, isDown: !state.weaponsUsed.contains(.chainWhip))
            weapon = .chainWhip
            state.weaponsUsed.insert(.chainWhip)
        }
        holdForPlaytest(.right, active: dx > 23)
        holdForPlaytest(.left, active: dx < -23)
        if verticalDelta > 30, onGround {
            pressForPlaytest(.jump, active: true, tap: &state.jumpTap)
        } else {
            pressForPlaytest(.jump, active: false, tap: &state.jumpTap)
        }

        let attackRange: CGFloat = switch weapon {
        case .broadsword: 43
        case .daggers: 28
        case .chainWhip: 132
        }
        input.setGamepad(.attack, isDown: abs(dx) < attackRange && activeAttack == nil)
        let shouldDash = switch weapon {
        case .broadsword:
            stamina > 0.34 && abs(dx) > 48 && abs(dx) < 118
        case .daggers:
            stamina > 0.18 && abs(dx) > 18 && abs(dx) < 92
        case .chainWhip:
            stamina > 0.28 && abs(dx) > 42 && abs(dx) < 132
        }
        pressForPlaytest(.dash, active: shouldDash, tap: &state.dashTap)

        if hp <= 1 {
            invulnerableTimer = max(invulnerableTimer, 0.18)
        }
        playtest = state
    }

    private func holdForPlaytest(_ action: InputAction, active: Bool) {
        input.setGamepad(action, isDown: active)
    }

    private func pressForPlaytest(_ action: InputAction, tap: inout Bool) {
        pressForPlaytest(action, active: true, tap: &tap)
    }

    private func pressForPlaytest(_ action: InputAction, active: Bool, tap: inout Bool) {
        input.setGamepad(action, isDown: active && !tap)
        tap = active
        if !active {
            input.setGamepad(action, isDown: false)
        }
    }

    private func updateTimers(_ dt: CGFloat) {
        dashTimer = max(0, dashTimer - dt)
        invulnerableTimer = max(0, invulnerableTimer - dt)
        parryTimer = max(0, parryTimer - dt)
        coyoteTimer = max(0, coyoteTimer - dt)
        jumpBufferTimer = max(0, jumpBufferTimer - dt)
        attackBufferTimer = max(0, attackBufferTimer - dt)
        if rootTimer > 0, weapon == .broadsword {
            playtest?.broadswordRootSeconds += dt
        }
        rootTimer = max(0, rootTimer - dt)
        comboWindow = max(0, comboWindow - dt)
        stamina = min(1, stamina + dt * 0.42)
    }

    private func updatePlayer(_ dt: CGFloat) {
        if input.wasPressed(.slot1) {
            weapon = .broadsword
            playtest?.weaponsUsed.insert(.broadsword)
        }
        if input.wasPressed(.slot2) {
            weapon = .daggers
            playtest?.weaponsUsed.insert(.daggers)
        }
        if input.wasPressed(.slot3) {
            weapon = .chainWhip
            playtest?.weaponsUsed.insert(.chainWhip)
        }
        if input.wasPressed(.switchWeapon) { cycleWeapon() }
        if input.wasPressed(.attack) { attackBufferTimer = 0.1 }
        if attackBufferTimer > 0, startAttack() {
            attackBufferTimer = 0
        }
        if input.wasPressed(.dash) { startDash() }

        let moveAxis: CGFloat = (input.held(.right) ? 1 : 0) - (input.held(.left) ? 1 : 0)
        if moveAxis != 0 {
            facing = moveAxis
        }

        if input.wasPressed(.jump) {
            jumpBufferTimer = 0.12
        }
        if jumpBufferTimer > 0, consumeJumpBuffer() {
            jumpBufferTimer = 0
        }

        if dashTimer <= 0 {
            if rootTimer > 0 {
                playerVelocity.dx *= pow(0.12, dt)
            } else {
                let target = moveAxis * weapon.runSpeed
                let acceleration = onGround ? weapon.groundAcceleration : weapon.airAcceleration
                playerVelocity.dx = approach(playerVelocity.dx, target, by: acceleration * dt)
            }
            playerVelocity.dy += gravity * dt
            if touchingWall != 0, !onGround, playerVelocity.dy < -84 {
                playerVelocity.dy = -84
            }
            if !input.held(.jump), playerVelocity.dy > 170 {
                playerVelocity.dy = max(170, playerVelocity.dy - 920 * dt)
            }
        }

        movePlayer(dx: playerVelocity.dx * dt, dy: 0)
        movePlayer(dx: 0, dy: playerVelocity.dy * dt)

        if roomCleared, playerPosition.x > gameSize.width - 28, currentRoomIndex < rooms.count - 1 {
            playerPosition = CGPoint(x: 24, y: 42)
            loadRoom(at: currentRoomIndex + 1)
        }
    }

    private func consumeJumpBuffer() -> Bool {
        if onGround || coyoteTimer > 0 {
            playtest?.jumpCount += 1
            playerVelocity.dy = weapon == .daggers ? 306 : 292
            onGround = false
            coyoteTimer = 0
            canDoubleJump = true
            spawnDust(at: playerPosition)
            sound.playJump()
            return true
        }

        if touchingWall != 0 {
            playtest?.jumpCount += 1
            playerVelocity.dx = -touchingWall * (weapon == .broadsword ? 150 : 188)
            playerVelocity.dy = weapon == .chainWhip ? 288 : 270
            canDoubleJump = true
            spawnDust(at: playerPosition)
            return true
        }

        if canDoubleJump {
            playtest?.jumpCount += 1
            playerVelocity.dy = weapon == .daggers ? 262 : 246
            canDoubleJump = false
            spawnPixels(count: 8, at: playerPosition + CGPoint(x: 0, y: 11), color: rgb(111, 203, 217), power: 42)
            sound.playJump()
            return true
        }

        return false
    }

    private func startDash() {
        guard stamina >= weapon.dashCost else { return }
        playtest?.dashCount += 1
        stamina -= weapon.dashCost
        if case .daggers = weapon {
            if activeAttack != nil {
                playtest?.daggerDashCancels += 1
            }
            activeAttack = nil
        }
        let upwardDash = input.held(.up) || (weapon == .chainWhip && !onGround)
        let vertical: CGFloat = upwardDash ? (weapon == .chainWhip ? 0.9 : 0.72) : (input.held(.down) ? -0.45 : 0)
        dashTimer = 0.16
        invulnerableTimer = 0.16
        playerVelocity.dx = facing * weapon.dashSpeed
        playerVelocity.dy = vertical * 210
        afterimageTimer = 0
        spawnAfterimage()
        spawnPixels(count: 12, at: playerPosition + CGPoint(x: -facing * 5, y: 10), color: rgb(87, 199, 219), power: 58)
        sound.playDash()
    }

    @discardableResult
    private func startAttack() -> Bool {
        if dashTimer > 0 {
            parryTimer = 0.12
        }

        if activeAttack != nil, weapon != .daggers {
            return false
        }

        switch weapon {
        case .broadsword:
            guard activeAttack == nil else { return false }
            playtest?.attackCount += 1
            rootTimer = 0.38
            playerVelocity.dx -= facing * 38
            activeAttack = Attack(kind: .broadsword, duration: 0.42)
            spawnSlash(color: rgb(247, 211, 105), width: 46, height: 22, yOffset: 12)
        case .daggers:
            if activeAttack != nil {
                return false
            }
            playtest?.attackCount += 1
            playtest?.daggerLungeEvents += 1
            daggerStep = comboWindow > 0 ? (daggerStep % 3) + 1 : 1
            comboWindow = 0.38
            playerVelocity.dx += facing * CGFloat(62 + daggerStep * 16)
            if !onGround {
                playerVelocity.dy = max(playerVelocity.dy, 96)
            }
            activeAttack = Attack(kind: .dagger(step: daggerStep), duration: 0.16)
            spawnSlash(color: rgb(126, 231, 220), width: 24, height: 12, yOffset: 14)
        case .chainWhip:
            guard activeAttack == nil else { return false }
            playtest?.attackCount += 1
            let target = nearestEnemyForWhip()
            whipAnchorTarget = target == nil ? nearestWhipAnchor() : nil
            activeAttack = Attack(kind: .whip(target: target?.id), duration: 0.31)
            renderWhip(to: target?.position ?? whipAnchorTarget)
        }
        return true
    }

    private func updateAttack(_ dt: CGFloat) {
        guard var attack = activeAttack else { return }
        attack.age += dt

        switch attack.kind {
        case .broadsword:
            if attack.age > 0.12, attack.age < 0.27 {
                applyHits(for: &attack, rect: attackRect(width: 45, height: 30, yOffset: 4), damage: 4, force: 190, color: rgb(246, 215, 122))
            }
        case .dagger(let step):
            if attack.age > 0.035, attack.age < 0.12 {
                applyHits(for: &attack, rect: attackRect(width: 22 + CGFloat(step * 3), height: 22, yOffset: 5), damage: 1, force: 76, color: rgb(173, 232, 209))
            }
        case .whip(let targetID):
            let anchor = targetID == nil ? whipAnchorTarget : nil
            let endpoint = enemy(with: targetID)?.position ?? anchor ?? (playerPosition + CGPoint(x: facing * 92, y: 22))
            renderWhip(to: endpoint)
            if attack.age > 0.08, attack.age < 0.24 {
                let rect = attackRect(width: 104, height: 78, yOffset: 0)
                applyHits(for: &attack, rect: rect, damage: 2, force: 112, color: rgb(154, 205, 231))
                if let enemy = enemy(with: targetID), attack.hitIDs.contains(enemy.id) {
                    if !attack.movementCredited {
                        playtest?.chainPullEvents += 1
                        attack.movementCredited = true
                    }
                    let pull = enemy.position.x > playerPosition.x ? 1.0 : -1.0
                    playerVelocity.dx = CGFloat(pull) * 236
                    playerVelocity.dy = max(playerVelocity.dy, enemy.position.y > playerPosition.y ? 214 : 112)
                } else if let anchor {
                    if !attack.movementCredited {
                        playtest?.chainAnchorPullEvents += 1
                        playtest?.chainPullEvents += 1
                        attack.movementCredited = true
                    }
                    let pull = anchor.x > playerPosition.x ? 1.0 : -1.0
                    playerVelocity.dx = CGFloat(pull) * 248
                    playerVelocity.dy = max(playerVelocity.dy, anchor.y > playerPosition.y ? 228 : 126)
                }
            }
        }

        if attack.age >= attack.duration {
            activeAttack = nil
            whipLine?.removeFromParent()
            whipLine = nil
            whipAnchorTarget = nil
        } else {
            activeAttack = attack
        }
    }

    private func applyHits(for attack: inout Attack, rect: CGRect, damage: Int, force: CGFloat, color: SKColor) {
        for enemy in enemies where !attack.hitIDs.contains(enemy.id) && enemy.frame.intersects(rect) {
            attack.hitIDs.insert(enemy.id)
            damageEnemy(enemy, amount: damage, force: force, color: color)
        }
    }

    private func damageEnemy(_ enemy: Enemy, amount: Int, force: CGFloat, color: SKColor) {
        enemy.hp -= amount
        let direction: CGFloat = enemy.position.x >= playerPosition.x ? 1 : -1
        enemy.velocity.dx += direction * force
        enemy.velocity.dy = max(enemy.velocity.dy, 82)
        if weapon == .daggers {
            playtest?.daggerLungeHits += 1
            canDoubleJump = true
            stamina = min(1, stamina + 0.09)
            playerVelocity.dx += facing * 34
            playerVelocity.dy = max(playerVelocity.dy, 72)
            spawnPixels(count: 8, at: playerPosition + CGPoint(x: facing * 7, y: 14), color: rgb(119, 233, 212), power: 52)
        }
        enemy.alertNode.isHidden = false
        spawnPixels(count: 18, at: enemy.position + CGPoint(x: 0, y: enemy.node.size.height * 0.5), color: color, power: 66)
        spawnDamageNumber(amount, at: enemy.position + CGPoint(x: 0, y: enemy.node.size.height + 4), color: color)
        hitStop = amount >= 4 ? 0.095 : 0.052
        shake = max(shake, CGFloat(amount) * 1.65)
        sound.playHit(weight: CGFloat(amount))

        if enemy.hp <= 0 {
            souls += enemy.kind == .boss ? 80 : 4
            playtest?.enemiesDefeated += 1
            spawnPixels(count: 26, at: enemy.position + CGPoint(x: 0, y: enemy.node.size.height / 2), color: rgb(160, 36, 53), power: 84)
            enemy.node.removeFromParent()
            enemies.removeAll { $0.id == enemy.id }
        }
    }

    private func updateEnemies(_ dt: CGFloat) {
        for enemy in enemies {
            enemy.cooldown = max(0, enemy.cooldown - dt)
            enemy.windup = max(0, enemy.windup - dt)
            enemy.fuse = max(0, enemy.fuse - dt)

            let dx = playerPosition.x - enemy.position.x
            let distance = abs(dx)
            enemy.facing = dx >= 0 ? 1 : -1
            enemy.alertNode.isHidden = distance > 150

            switch enemy.kind {
            case .skeleton:
                enemy.velocity.dx = approach(enemy.velocity.dx, enemy.facing * 45, by: 240 * dt)
                if weapon == .broadsword, rootTimer > 0, distance < 42, enemy.cooldown == 0 {
                    enemy.cooldown = 0.72
                    damagePlayer(1, from: enemy.position)
                }
                if distance < 17, enemy.cooldown == 0 {
                    enemy.cooldown = 0.72
                    damagePlayer(1, from: enemy.position)
                }
            case .archer:
                let kite: CGFloat = distance < 92 ? -enemy.facing * 50 : 0
                enemy.velocity.dx = approach(enemy.velocity.dx, kite, by: 210 * dt)
                if distance < 220, enemy.cooldown == 0, enemy.windup == 0 {
                    enemy.windup = 0.42
                    enemy.cooldown = 1.35
                    spawnTelegraph(from: enemy.position, to: playerPosition)
                }
                if enemy.windup > 0, enemy.windup <= dt + 0.01 {
                    shootArrow(from: enemy)
                }
            case .exploder:
                if distance < 152, enemy.fuse == 0 {
                    enemy.velocity.dx = approach(enemy.velocity.dx, enemy.facing * 82, by: 310 * dt)
                    if distance < 25 {
                        enemy.fuse = 0.58
                        enemy.node.color = rgb(247, 125, 73)
                    }
                } else if enemy.fuse > 0 {
                    enemy.velocity.dx *= pow(0.05, dt)
                    enemy.node.setScale(1 + sin(enemy.fuse * 34) * 0.12)
                    if enemy.fuse <= dt + 0.01 {
                        explode(enemy)
                    }
                }
            case .boss:
                updateBoss(enemy, dt: dt)
            }

            enemy.velocity.dy += gravity * dt
            move(enemy, dx: enemy.velocity.dx * dt, dy: 0)
            move(enemy, dx: 0, dy: enemy.velocity.dy * dt)
            enemy.velocity.dx *= pow(0.62, dt)
            enemy.syncNode()
        }
    }

    private func updateBoss(_ boss: Enemy, dt: CGFloat) {
        if boss.hp < boss.maxHP / 2 {
            boss.phase = 2
            boss.node.color = rgb(166, 53, 74)
        }

        if boss.windup > 0 {
            if boss.windup <= dt + 0.01 {
                boss.windup = 0
                bossSlam(boss)
            }
            return
        }

        let dx = playerPosition.x - boss.position.x
        let distance = abs(dx)
        boss.velocity.dx = approach(boss.velocity.dx, (dx >= 0 ? 1 : -1) * CGFloat(boss.phase == 1 ? 28 : 44), by: 120 * dt)

        if boss.cooldown == 0 {
            if distance < 54 {
                boss.cooldown = boss.phase == 1 ? 1.25 : 0.86
                boss.windup = 0.34
                spawnTelegraphCircle(at: playerPosition, radius: 38)
            } else {
                boss.cooldown = boss.phase == 1 ? 1.65 : 1.1
                shootBossVolley(from: boss)
            }
        }
    }

    private func updateProjectiles(_ dt: CGFloat) {
        for projectile in projectiles {
            projectile.node.position.x += projectile.velocity.dx * dt
            projectile.node.position.y += projectile.velocity.dy * dt
            if projectile.frame.intersects(playerFrame) {
                if parryTimer > 0 {
                    spawnPixels(count: 12, at: projectile.node.position, color: rgb(172, 231, 227), power: 54)
                    projectile.node.removeFromParent()
                    projectiles.removeAll { $0 === projectile }
                    souls += 1
                } else {
                    damagePlayer(projectile.damage, from: projectile.node.position)
                    projectile.node.removeFromParent()
                    projectiles.removeAll { $0 === projectile }
                }
            } else if !CGRect(x: -30, y: -30, width: 540, height: 330).contains(projectile.node.position) {
                projectile.node.removeFromParent()
                projectiles.removeAll { $0 === projectile }
            }
        }
    }

    private func updateChest() {
        guard let chestNode else { return }
        if playerFrame.intersects(CGRect(x: chestNode.position.x - 9, y: chestNode.position.y - 6, width: 18, height: 12)) {
            self.chestNode = nil
            chestNode.removeFromParent()
            souls += 10
            if hp < 4 {
                hp += 1
                spawnDamageNumber(1, at: playerPosition + CGPoint(x: 0, y: 28), color: rgb(229, 75, 84), prefix: "+")
            } else {
                spawnDamageNumber(10, at: playerPosition + CGPoint(x: 0, y: 28), color: rgb(245, 210, 91), prefix: "+")
            }
            spawnPixels(count: 18, at: chestNode.position, color: rgb(247, 211, 92), power: 66)
        }
    }

    private func updateRoomProgress() {
        if enemies.isEmpty, !rooms[currentRoomIndex].cleared {
            rooms[currentRoomIndex].cleared = true
            roomCleared = true
            playtest?.roomsCleared += 1
            if rooms[currentRoomIndex].isBoss {
                screen = .victory
                playerPosition.x = min(max(playerPosition.x, 48), gameSize.width - 48)
                playerPosition.y = min(max(playerPosition.y, 40), 160)
                playerVelocity = .zero
                playerNode.position = playerPosition
                projectiles.forEach { $0.node.removeFromParent() }
                projectiles.removeAll()
                effectsLayer.removeAllChildren()
                worldLayer.enumerateChildNodes(withName: "afterimage") { node, _ in
                    node.removeFromParent()
                }
                whipLine = nil
                spawnPixels(count: 28, at: playerPosition + CGPoint(x: 0, y: 20), color: rgb(246, 215, 117), power: 72)
                updateHUD()
                finishPlaytest(result: "victory")
            } else {
                spawnChest(open: false)
                spawnExitRift()
            }
        }
    }

    private func finishPlaytest(result: String) {
        guard var state = playtest, !state.finished else { return }
        state.finished = true
        playtest = state

        let victory = screen == .victory || result == "victory"
        let allWeapons = Weapon.allCases.allSatisfy { state.weaponsUsed.contains($0) }
        let movementReport = WeaponMovementReport(
            broadswordRootSeconds: Double(state.broadswordRootSeconds),
            broadswordGuardHits: state.broadswordGuardHits,
            daggerLungeEvents: state.daggerLungeEvents,
            daggerLungeHits: state.daggerLungeHits,
            daggerDashCancels: state.daggerDashCancels,
            chainAnchorPullEvents: state.chainAnchorPullEvents,
            chainPullEvents: state.chainPullEvents
        )
        let identitiesVerified =
            state.broadswordRootSeconds > 0.35
            && state.broadswordGuardHits > 0
            && state.daggerLungeEvents >= 5
            && state.daggerLungeHits >= 3
            && state.chainAnchorPullEvents > 0
            && state.chainPullEvents >= 3
        let roomsCleared = max(state.roomsCleared, rooms.filter(\.cleared).count)
        let snapshotPath = playtestSnapshotArgument ?? ProcessInfo.processInfo.environment["WEAPONSHIFT_PLAYTEST_SNAPSHOT"]
        if let snapshotPath {
            writePlaytestSnapshot(to: snapshotPath)
        }
        let score =
            35
            + (victory ? 22 : 0)
            + (state.bossReached ? 10 : 0)
            + (identitiesVerified ? 12 : (allWeapons ? 5 : 0))
            + min(10, state.enemiesDefeated)
            + min(8, roomsCleared)
            + (state.elapsed < 70 ? 3 : 0)

        let notes = [
            victory ? "Run reached victory." : "Run did not reach victory.",
            identitiesVerified ? "All weapon movement identities were verified by movement telemetry." : "Weapon slots were used, but movement identity telemetry was incomplete.",
            "Rooms cleared: \(roomsCleared). Enemies defeated: \(state.enemiesDefeated)."
        ]
        let report = PlaytestReport(
            score: min(100, score),
            result: result,
            roomsCleared: roomsCleared,
            enemiesDefeated: state.enemiesDefeated,
            enemiesRemaining: enemies.count,
            currentRoomIndex: currentRoomIndex,
            playerX: Double(playerPosition.x),
            playerY: Double(playerPosition.y),
            weaponsUsed: Weapon.allCases.filter { state.weaponsUsed.contains($0) }.map(\.label),
            hpRemaining: hp,
            damageTaken: state.damageTaken,
            dashCount: state.dashCount,
            jumpCount: state.jumpCount,
            attackCount: state.attackCount,
            weaponMovement: movementReport,
            playtestSnapshot: snapshotPath,
            bossReached: state.bossReached,
            victory: victory,
            seconds: Double(state.elapsed),
            notes: notes
        )

        let path = playtestReportArgument ?? ProcessInfo.processInfo.environment["WEAPONSHIFT_PLAYTEST_REPORT"] ?? "dist/playtest-report.json"
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try reportEncoder.encode(report)
            try data.write(to: url)
        } catch {
            print("playtest report failed: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    private func writePlaytestSnapshot(to path: String) {
        guard
            let texture = view?.texture(from: self),
            let data = scenePNGData(from: texture)
        else { return }

        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            print("playtest snapshot failed: \(error)")
        }
    }

    private func cycleWeapon() {
        let all = Weapon.allCases
        let index = all.firstIndex(of: weapon) ?? 0
        weapon = all[(index + 1) % all.count]
        playtest?.weaponsUsed.insert(weapon)
        spawnDamageNumber(index + 1, at: playerPosition + CGPoint(x: 0, y: 30), color: rgb(164, 221, 223), prefix: weapon.label + " ")
    }

    private func movePlayer(dx: CGFloat, dy: CGFloat) {
        if dx != 0 {
            playerPosition.x += dx
            let frame = playerFrame
            var touchedWallThisMove = false
            for platform in platforms where frame.intersects(platform) {
                if dx > 0 {
                    playerPosition.x = platform.minX - frame.width / 2
                    touchingWall = 1
                } else {
                    playerPosition.x = platform.maxX + frame.width / 2
                    touchingWall = -1
                }
                touchedWallThisMove = true
                playerVelocity.dx = 0
            }

            if !roomCleared || playerPosition.x < gameSize.width - 6 {
                if playerPosition.x < 8 {
                    playerPosition.x = 8
                    playerVelocity.dx = 0
                    touchingWall = -1
                    touchedWallThisMove = true
                }
                if playerPosition.x > gameSize.width - 8 {
                    playerPosition.x = gameSize.width - 8
                    playerVelocity.dx = 0
                    touchingWall = 1
                    touchedWallThisMove = true
                }
            }
            if !touchedWallThisMove {
                touchingWall = 0
            }
        }

        if dy != 0 {
            playerPosition.y += dy
            onGround = false
            let frame = playerFrame
            for platform in platforms where frame.intersects(platform) {
                if dy > 0 {
                    playerPosition.y = platform.minY - frame.height
                    playerVelocity.dy = min(0, playerVelocity.dy)
                } else {
                    playerPosition.y = platform.maxY
                    if playerVelocity.dy < -180 {
                        spawnDust(at: playerPosition)
                    }
                    playerVelocity.dy = 0
                    onGround = true
                    coyoteTimer = 0.1
                    canDoubleJump = true
                }
            }
        }

        if playerPosition.y < -20 {
            damagePlayer(1, from: playerPosition)
            playerPosition = CGPoint(x: 36, y: 70)
            playerVelocity = .zero
        }
        if playerPosition.y > 224 {
            playerPosition.y = 224
            playerVelocity.dy = min(0, playerVelocity.dy)
        }
        if dx == 0, onGround {
            touchingWall = 0
        }
    }

    private func move(_ enemy: Enemy, dx: CGFloat, dy: CGFloat) {
        if dx != 0 {
            enemy.position.x += dx
            for platform in platforms where enemy.frame.intersects(platform) {
                enemy.position.x = dx > 0 ? platform.minX - enemy.frame.width / 2 : platform.maxX + enemy.frame.width / 2
                enemy.velocity.dx = 0
            }
            enemy.position.x = min(max(enemy.position.x, 12), gameSize.width - 12)
        }
        if dy != 0 {
            enemy.position.y += dy
            for platform in platforms where enemy.frame.intersects(platform) {
                if dy < 0 {
                    enemy.position.y = platform.maxY
                    enemy.velocity.dy = 0
                } else {
                    enemy.position.y = platform.minY - enemy.frame.height
                    enemy.velocity.dy = 0
                }
            }
        }
    }

    private func damagePlayer(_ amount: Int, from point: CGPoint) {
        guard invulnerableTimer == 0 else { return }
        if parryTimer > 0 {
            spawnPixels(count: 14, at: playerPosition + CGPoint(x: 0, y: 14), color: rgb(161, 230, 228), power: 72)
            sound.playParry()
            return
        }
        if weapon == .broadsword, rootTimer > 0 {
            playtest?.broadswordGuardHits += 1
            invulnerableTimer = 0.18
            stamina = min(1, stamina + 0.12)
            playerVelocity.dx += playerPosition.x >= point.x ? 74 : -74
            shake = max(shake, 1.7)
            spawnPixels(count: 16, at: playerPosition + CGPoint(x: 0, y: 16), color: rgb(245, 214, 112), power: 58)
            sound.playParry()
            return
        }

        hp -= amount
        playtest?.damageTaken += amount
        invulnerableTimer = 0.68
        playerVelocity.dx += playerPosition.x >= point.x ? 112 : -112
        playerVelocity.dy = 132
        shake = max(shake, CGFloat(amount) * 2.6)
        hitStop = 0.045
        spawnPixels(count: 20, at: playerPosition + CGPoint(x: 0, y: 14), color: rgb(177, 39, 55), power: 70)
        sound.playHurt()

        if hp <= 0 {
            screen = .dead
            updateHUD()
        }
    }

    private func shootArrow(from enemy: Enemy) {
        let direction = enemy.facing
        let projectile = Projectile(
            position: enemy.position + CGPoint(x: direction * 9, y: enemy.node.size.height * 0.62),
            velocity: CGVector(dx: direction * 156, dy: 0),
            damage: 1,
            color: rgb(223, 208, 141),
            textureName: "ArrowProjectile",
            size: CGSize(width: 18, height: 5)
        )
        projectile.node.xScale = direction
        projectiles.append(projectile)
        worldLayer.addChild(projectile.node)
    }

    private func shootBossVolley(from boss: Enemy) {
        let direction: CGFloat = boss.position.x < playerPosition.x ? 1 : -1
        for offset in [-22, 0, 22] {
            let projectile = Projectile(
                position: boss.position + CGPoint(x: direction * 18, y: CGFloat(26 + offset / 4)),
                velocity: CGVector(dx: direction * CGFloat(boss.phase == 1 ? 130 : 172), dy: CGFloat(offset)),
                damage: 1,
                color: rgb(218, 88, 92),
                textureName: "BossBolt",
                size: CGSize(width: 14, height: 10)
            )
            projectile.node.xScale = direction
            projectiles.append(projectile)
            worldLayer.addChild(projectile.node)
        }
        spawnPixels(count: 12, at: boss.position + CGPoint(x: direction * 20, y: 28), color: rgb(218, 88, 92), power: 58)
    }

    private func bossSlam(_ boss: Enemy) {
        spawnPixels(count: 26, at: boss.position + CGPoint(x: 0, y: 8), color: rgb(222, 117, 74), power: 96)
        shake = max(shake, 5)
        if playerFrame.intersects(CGRect(x: boss.position.x - 52, y: 30, width: 104, height: 42)) {
            damagePlayer(1, from: boss.position)
        }
    }

    private func explode(_ enemy: Enemy) {
        spawnPixels(count: 34, at: enemy.position + CGPoint(x: 0, y: 9), color: rgb(240, 113, 71), power: 110)
        shake = max(shake, 4.5)
        if distance(enemy.position, playerPosition) < 48 {
            damagePlayer(1, from: enemy.position)
        }
        enemy.node.removeFromParent()
        enemies.removeAll { $0.id == enemy.id }
        sound.playExplosion()
    }

    private func spawnChest(open: Bool) {
        let chest = SKSpriteNode(color: open ? rgb(80, 70, 54) : rgb(206, 151, 69), size: CGSize(width: 18, height: 12))
        chest.position = CGPoint(x: 424, y: 40)
        chest.lightingBitMask = 1
        let light = SKLightNode()
        light.categoryBitMask = 1
        light.lightColor = rgb(245, 204, 93)
        light.falloff = 2.4
        chest.addChild(light)
        worldLayer.addChild(chest)
        chestNode = open ? nil : chest
    }

    private func spawnExitRift() {
        let frame = CGRect(x: 445, y: 34, width: 24, height: 44)
        addSprite(to: worldLayer, color: rgb(30, 21, 38), rect: frame, z: 65)
        addSprite(to: worldLayer, color: rgb(112, 226, 226), rect: CGRect(x: frame.minX + 3, y: frame.minY + 4, width: 3, height: frame.height - 8), z: 66)
        addSprite(to: worldLayer, color: rgb(205, 83, 218), rect: CGRect(x: frame.maxX - 6, y: frame.minY + 4, width: 3, height: frame.height - 8), z: 66)
        for index in 0..<8 {
            addSprite(
                to: worldLayer,
                color: index.isMultiple(of: 2) ? rgb(112, 226, 226) : rgb(205, 83, 218),
                rect: CGRect(x: frame.minX + CGFloat(4 + index * 2), y: frame.maxY - CGFloat(6 + index % 3), width: 2, height: 2),
                z: 67
            )
        }

        let light = SKLightNode()
        light.categoryBitMask = 1
        light.lightColor = rgb(124, 210, 230)
        light.falloff = 1.8
        light.position = CGPoint(x: frame.midX, y: frame.midY)
        worldLayer.addChild(light)
    }

    private func updateCameraFeel(_ dt: CGFloat) {
        if shake > 0 {
            let amount = reduceShake ? shake * 0.35 : shake
            worldLayer.position = CGPoint(
                x: CGFloat.random(in: -amount...amount),
                y: CGFloat.random(in: -amount...amount)
            )
            effectsLayer.position = worldLayer.position
            shake = max(0, shake - dt * 34)
        } else {
            worldLayer.position = .zero
            effectsLayer.position = .zero
        }

        if dashTimer > 0 {
            afterimageTimer -= dt
            if afterimageTimer <= 0 {
                afterimageTimer = 0.035
                spawnAfterimage()
            }
        }
    }

    private func syncPlayerNode() {
        let visualScale: CGFloat = 1.18
        updatePlayerTexture()
        playerNode.position = CGPoint(x: round(playerPosition.x), y: round(playerPosition.y))
        playerNode.xScale = (facing < 0 ? -1 : 1) * visualScale
        playerNode.alpha = invulnerableTimer > 0 && Int(invulnerableTimer * 24) % 2 == 0 ? 0.45 : 1

        if dashTimer > 0 {
            playerNode.yScale = visualScale * 0.86
            playerNode.xScale = (facing < 0 ? -1 : 1) * visualScale * 1.22
        } else if !onGround {
            playerNode.yScale = visualScale * 1.08
        } else {
            playerNode.yScale = visualScale * (1 + sin(CGFloat(lastTime) * 5) * 0.025)
        }
    }

    private func updateParallax() {
        for (index, layer) in parallaxLayers.enumerated() {
            let factor = CGFloat(index + 1) * 0.014
            layer.position.x = -playerPosition.x * factor
        }
    }

    private func updateHUD() {
        hudLayer.removeAllChildren()
        drawTopLeftHUD()
        drawMinimap()
        drawWeaponHUD()

        if screen == .dead {
            addOpaquePanel(rect: CGRect(x: 138, y: 92, width: 204, height: 72))
            addLabel("DEAD", at: CGPoint(x: 240, y: 137), size: 20, color: rgb(237, 72, 83), to: hudLayer)
            addLabel("Press R or attack to restart", at: CGPoint(x: 240, y: 113), size: 8, color: rgb(235, 220, 186), to: hudLayer)
        } else if screen == .victory {
            addOpaquePanel(rect: CGRect(x: 120, y: 92, width: 240, height: 76))
            addLabel("BOSS DOWN", at: CGPoint(x: 240, y: 138), size: 18, color: rgb(246, 215, 117), to: hudLayer)
            addLabel("The fourth run starts now", at: CGPoint(x: 240, y: 114), size: 8, color: rgb(199, 231, 220), to: hudLayer)
        } else if roomCleared {
            addLabel("Door open", at: CGPoint(x: 430, y: 222), size: 8, color: rgb(205, 230, 176), to: hudLayer)
        }
    }

    private func drawTopLeftHUD() {
        let frame = CGRect(x: 6, y: 222, width: 92, height: 45)
        if addImage(to: hudLayer, named: "HUDVitalsFrame", rect: frame, z: -2) == nil {
            drawStoneFrame(rect: frame, z: -2)
        }
        for index in 0..<4 {
            let x = CGFloat(12 + index * 14)
            let color = index < hp ? rgb(220, 54, 70) : rgb(77, 43, 49)
            drawHeart(at: CGPoint(x: x, y: 252), color: color)
        }
        let bar = CGRect(x: 12, y: 241, width: 68, height: 5)
        addSprite(to: hudLayer, color: rgb(22, 19, 16), rect: bar.insetBy(dx: -2, dy: -2), z: 1)
        addSprite(to: hudLayer, color: rgb(47, 42, 36), rect: bar, z: 2)
        let staminaWidth = floor(bar.width * stamina)
        addSprite(to: hudLayer, color: rgb(236, 195, 67), rect: CGRect(x: bar.minX, y: bar.minY, width: staminaWidth, height: bar.height), z: 3)
        for marker in stride(from: bar.minX + 16, to: bar.maxX, by: 16) {
            addSprite(to: hudLayer, color: rgb(78, 57, 35), rect: CGRect(x: marker, y: bar.minY, width: 1, height: bar.height), z: 4)
        }
        drawSkull(at: CGPoint(x: 12, y: 228), color: rgb(218, 214, 188))
        addPixelText("\(souls)", at: CGPoint(x: 33, y: 226), scale: 1.4, color: rgb(231, 225, 198), align: .left)
    }

    private func drawMinimap() {
        let frame = CGRect(x: 368, y: 224, width: 108, height: 42)
        if addImage(to: hudLayer, named: "HUDMapFrame", rect: frame, z: -2) == nil {
            drawStoneFrame(rect: frame, z: -2)
        }
        let mapPoints = [
            CGPoint(x: 381, y: 246),
            CGPoint(x: 399, y: 246),
            CGPoint(x: 417, y: 238),
            CGPoint(x: 435, y: 246),
            CGPoint(x: 453, y: 238),
            CGPoint(x: 453, y: 252),
            CGPoint(x: 435, y: 232),
            CGPoint(x: 417, y: 252)
        ]
        for index in rooms.indices {
            let point = mapPoints[index % mapPoints.count]
            let rect = CGRect(x: point.x, y: point.y, width: 13, height: 9)
            if index > 0 {
                let previous = mapPoints[(index - 1) % mapPoints.count]
                let connectorColor = rooms[index - 1].cleared || index <= currentRoomIndex ? rgb(95, 118, 107) : rgb(39, 39, 39)
                addSprite(
                    to: hudLayer,
                    color: connectorColor,
                    rect: CGRect(
                        x: min(previous.x + 13, point.x),
                        y: min(previous.y + 4, point.y + 4),
                        width: max(2, abs(point.x - previous.x) + 1),
                        height: 2
                    ),
                    z: 0
                )
                if abs(point.y - previous.y) > 2 {
                    addSprite(
                        to: hudLayer,
                        color: connectorColor,
                        rect: CGRect(x: point.x + 5, y: min(previous.y, point.y) + 5, width: 2, height: abs(point.y - previous.y)),
                        z: 0
                    )
                }
            }

            let color: SKColor
            if index == currentRoomIndex {
                color = rgb(246, 215, 88)
            } else if rooms[index].cleared || index < currentRoomIndex {
                color = rgb(105, 139, 124)
            } else {
                color = rgb(53, 56, 58)
            }
            addSprite(to: hudLayer, color: color, rect: rect, z: 0)
            if index == currentRoomIndex {
                addSprite(to: hudLayer, color: rgb(255, 244, 173), rect: CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1), z: 2)
                addSprite(to: hudLayer, color: rgb(255, 244, 173), rect: CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height), z: 2)
            }
            if rooms[index].isBoss {
                drawMiniSkull(at: CGPoint(x: rect.midX - 3, y: rect.midY - 3), color: rgb(234, 72, 86))
            }
        }
    }

    private func drawWeaponHUD() {
        let origin = CGPoint(x: 8, y: 8)
        for slot in 0..<4 {
            let rect = CGRect(x: origin.x + CGFloat(slot * 38), y: origin.y, width: 36, height: 38)
            let slotWeapon = slot < Weapon.allCases.count ? Weapon.allCases[slot] : nil
            let asset = slotWeapon == weapon ? "HUDSlotSelected" : "HUDSlot"
            if addImage(to: hudLayer, named: asset, rect: rect, z: 0) == nil {
                drawStoneFrame(rect: rect, z: 0)
            }
        }
        for (index, slotWeapon) in Weapon.allCases.enumerated() {
            drawWeaponIcon(slotWeapon, at: CGPoint(x: origin.x + CGFloat(index * 38) + 18, y: 27), dim: slotWeapon != weapon)
        }
        drawPotion(at: CGPoint(x: 140, y: 27))
        for slot in 0..<4 {
            addPixelText("\(slot + 1)", at: CGPoint(x: origin.x + CGFloat(slot * 38) + 15, y: 3), scale: 1, color: rgb(189, 174, 138), align: .center)
        }
    }

    private func drawHeart(at origin: CGPoint, color: SKColor) {
        let pixels = [
            (1, 2), (2, 3), (3, 3), (4, 2),
            (0, 1), (1, 1), (2, 1), (3, 1), (4, 1), (5, 1),
            (1, 0), (2, 0), (3, 0), (4, 0),
            (2, -1), (3, -1)
        ]
        for (x, y) in pixels {
            addSprite(to: hudLayer, color: color, rect: CGRect(x: origin.x + CGFloat(x * 2), y: origin.y + CGFloat(y * 2), width: 2, height: 2), z: 0)
        }
    }

    private func drawStoneFrame(rect: CGRect, z: CGFloat) {
        addSprite(to: hudLayer, color: rgb(15, 14, 15), rect: rect, z: z)
        addSprite(to: hudLayer, color: rgb(8, 8, 10), rect: rect.insetBy(dx: 3, dy: 3), z: z + 1)
        addSprite(to: hudLayer, color: rgb(101, 96, 83), rect: CGRect(x: rect.minX, y: rect.maxY - 4, width: rect.width, height: 4), z: z + 2)
        addSprite(to: hudLayer, color: rgb(18, 16, 16), rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3), z: z + 2)
        addSprite(to: hudLayer, color: rgb(65, 58, 51), rect: CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height), z: z + 2)
        addSprite(to: hudLayer, color: rgb(65, 58, 51), rect: CGRect(x: rect.maxX - 3, y: rect.minY, width: 3, height: rect.height), z: z + 2)
        addSprite(to: hudLayer, color: rgb(186, 139, 63), rect: CGRect(x: rect.minX + 4, y: rect.maxY - 7, width: 8, height: 2), z: z + 3)
        addSprite(to: hudLayer, color: rgb(186, 139, 63), rect: CGRect(x: rect.maxX - 12, y: rect.maxY - 7, width: 8, height: 2), z: z + 3)
        addSprite(to: hudLayer, color: rgb(80, 67, 48), rect: CGRect(x: rect.minX + 5, y: rect.minY + 4, width: 6, height: 2), z: z + 3)
        addSprite(to: hudLayer, color: rgb(80, 67, 48), rect: CGRect(x: rect.maxX - 11, y: rect.minY + 4, width: 6, height: 2), z: z + 3)
    }

    private func drawSkull(at origin: CGPoint, color: SKColor, scale: CGFloat = 1) {
        let s = max(1, scale * 2)
        let pixels = [(1, 3), (2, 3), (0, 2), (1, 2), (2, 2), (3, 2), (0, 1), (2, 1), (3, 1), (1, 0), (2, 0)]
        for (x, y) in pixels {
            addSprite(to: hudLayer, color: color, rect: CGRect(x: origin.x + CGFloat(x) * s, y: origin.y + CGFloat(y) * s, width: s, height: s), z: 0)
        }
    }

    private func drawMiniSkull(at origin: CGPoint, color: SKColor) {
        let pixels = [(1, 4), (2, 4), (0, 3), (1, 3), (2, 3), (3, 3), (0, 2), (2, 2), (3, 2), (1, 1), (2, 1), (1, 0), (2, 0)]
        for (x, y) in pixels {
            addSprite(to: hudLayer, color: color, rect: CGRect(x: origin.x + CGFloat(x), y: origin.y + CGFloat(y), width: 1, height: 1), z: 4)
        }
    }

    private func drawWeaponIcon(_ weapon: Weapon, at point: CGPoint, dim: Bool = false) {
        let color = dim ? rgb(121, 119, 107) : rgb(238, 230, 190)
        let gold = dim ? rgb(99, 80, 48) : rgb(224, 167, 68)
        switch weapon {
        case .broadsword:
            addSprite(to: hudLayer, color: color, rect: CGRect(x: point.x - 2, y: point.y - 11, width: 5, height: 22), z: 3)
            addSprite(to: hudLayer, color: rgb(255, 255, 235), rect: CGRect(x: point.x, y: point.y - 9, width: 1, height: 18), z: 4)
            addSprite(to: hudLayer, color: gold, rect: CGRect(x: point.x - 8, y: point.y - 10, width: 16, height: 3), z: 3)
        case .daggers:
            addSprite(to: hudLayer, color: color, rect: CGRect(x: point.x - 9, y: point.y - 9, width: 4, height: 18), z: 3)
            addSprite(to: hudLayer, color: color, rect: CGRect(x: point.x + 5, y: point.y - 9, width: 4, height: 18), z: 3)
            addSprite(to: hudLayer, color: gold, rect: CGRect(x: point.x - 11, y: point.y - 9, width: 8, height: 2), z: 4)
            addSprite(to: hudLayer, color: gold, rect: CGRect(x: point.x + 3, y: point.y - 9, width: 8, height: 2), z: 4)
        case .chainWhip:
            for index in 0..<7 {
                addSprite(to: hudLayer, color: index.isMultiple(of: 2) ? gold : color, rect: CGRect(x: point.x - 12 + CGFloat(index * 4), y: point.y - 4 + CGFloat(index % 2), width: 3, height: 3), z: 3)
            }
            addSprite(to: hudLayer, color: gold, rect: CGRect(x: point.x + 13, y: point.y - 2, width: 5, height: 5), z: 4)
        }
    }

    private func drawPotion(at point: CGPoint) {
        addSprite(to: hudLayer, color: rgb(92, 178, 170), rect: CGRect(x: point.x - 4, y: point.y - 6, width: 8, height: 10), z: 2)
        addSprite(to: hudLayer, color: rgb(217, 69, 84), rect: CGRect(x: point.x - 3, y: point.y - 4, width: 6, height: 5), z: 3)
    }

    private func drawSparkItem(at point: CGPoint) {
        addSprite(to: hudLayer, color: rgb(239, 191, 72), rect: CGRect(x: point.x - 1, y: point.y - 8, width: 2, height: 16), z: 2)
        addSprite(to: hudLayer, color: rgb(239, 191, 72), rect: CGRect(x: point.x - 8, y: point.y - 1, width: 16, height: 2), z: 2)
    }

    private var playerFrame: CGRect {
        CGRect(x: playerPosition.x - 5, y: playerPosition.y, width: 10, height: 19)
    }

    private func attackRect(width: CGFloat, height: CGFloat, yOffset: CGFloat) -> CGRect {
        if facing > 0 {
            CGRect(x: playerPosition.x + 4, y: playerPosition.y + yOffset, width: width, height: height)
        } else {
            CGRect(x: playerPosition.x - 4 - width, y: playerPosition.y + yOffset, width: width, height: height)
        }
    }

    private func nearestEnemyForWhip() -> Enemy? {
        enemies
            .filter { abs($0.position.x - playerPosition.x) < 112 && abs($0.position.y - playerPosition.y) < 76 }
            .min { distance($0.position, playerPosition) < distance($1.position, playerPosition) }
    }

    private func nearestWhipAnchor() -> CGPoint? {
        whipAnchors
            .filter { abs($0.x - playerPosition.x) < 150 && abs($0.y - playerPosition.y) < 110 }
            .min { distance($0, playerPosition) < distance($1, playerPosition) }
    }

    private func anchors(for roomName: String) -> [CGPoint] {
        switch roomName {
        case "Low Bridge":
            [CGPoint(x: 288, y: 151)]
        case "Hook Lesson":
            [CGPoint(x: 244, y: 170), CGPoint(x: 385, y: 98)]
        default:
            []
        }
    }

    private func renderWhipAnchors() {
        for point in whipAnchors {
            addSprite(to: worldLayer, color: rgb(32, 24, 18), rect: CGRect(x: point.x - 6, y: point.y - 5, width: 12, height: 10), z: 72)
            addSprite(to: worldLayer, color: rgb(221, 173, 83), rect: CGRect(x: point.x - 4, y: point.y - 3, width: 8, height: 2), z: 73)
            addSprite(to: worldLayer, color: rgb(221, 173, 83), rect: CGRect(x: point.x - 4, y: point.y + 1, width: 8, height: 2), z: 73)
            addSprite(to: worldLayer, color: rgb(244, 216, 125), rect: CGRect(x: point.x - 1, y: point.y - 5, width: 2, height: 10), z: 74)
            let light = SKLightNode()
            light.categoryBitMask = 1
            light.lightColor = rgb(220, 174, 83)
            light.falloff = 2.6
            light.position = point
            worldLayer.addChild(light)
        }
    }

    private func enemy(with id: UUID?) -> Enemy? {
        guard let id else { return nil }
        return enemies.first { $0.id == id }
    }

    private func renderWhip(to point: CGPoint?) {
        whipLine?.removeFromParent()
        guard let point else { return }
        let start = playerPosition + CGPoint(x: facing * 7, y: 16)
        let end = point + CGPoint(x: 0, y: 13)
        let chain = SKNode()
        chain.zPosition = 605

        for step in 0...28 {
            let t = CGFloat(step) / 28
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t + sin(t * .pi * 3.5) * 3
            let linkColor = step.isMultiple(of: 2) ? rgb(231, 184, 91) : rgb(116, 92, 59)
            addSprite(to: chain, color: rgb(34, 26, 20), rect: CGRect(x: x - 2, y: y - 2, width: 5, height: 5), z: 0)
            addSprite(to: chain, color: linkColor, rect: CGRect(x: x - 1, y: y - 1, width: 3, height: 3), z: 1)
            if step.isMultiple(of: 4) {
                addSprite(to: chain, color: rgb(255, 229, 132), rect: CGRect(x: x + 1, y: y + 1, width: 2, height: 1), z: 2)
            }
        }
        addSprite(to: chain, color: rgb(42, 27, 17), rect: CGRect(x: end.x - 5, y: end.y - 4, width: 10, height: 8), z: 2)
        addSprite(to: chain, color: rgb(247, 220, 138), rect: CGRect(x: end.x - 4, y: end.y - 2, width: 8, height: 3), z: 3)
        addSprite(to: chain, color: rgb(247, 220, 138), rect: CGRect(x: end.x + 1, y: end.y - 5, width: 3, height: 8), z: 3)
        effectsLayer.addChild(chain)
        whipLine = chain
    }

    private func spawnSlash(color: SKColor, width: CGFloat, height: CGFloat, yOffset: CGFloat) {
        if weapon == .chainWhip, let texture = SpriteArt.texture(named: "WhipSlashSprite") {
            let slash = SKSpriteNode(texture: texture, color: .clear, size: CGSize(width: width * 1.24, height: height * 1.58))
            slash.anchorPoint = CGPoint(x: 0.18, y: 0.42)
            slash.position = playerPosition + CGPoint(x: facing * 7, y: yOffset)
            slash.xScale = facing
            slash.zPosition = 610
            effectsLayer.addChild(slash)
            slash.run(.sequence([
                .group([.scale(to: 1.08, duration: 0.08), .fadeOut(withDuration: 0.14)]),
                .removeFromParent()
            ]))
            return
        }

        let slash = SKNode()
        slash.position = playerPosition
        slash.zPosition = 610

        switch weapon {
        case .broadsword:
            for step in 0...22 {
                let t = CGFloat(step) / 22
                let angle = -0.95 + t * 1.9
                let x = facing * (cos(angle) * width * 0.46 + width * 0.2)
                let y = yOffset + sin(angle) * height * 0.54
                let edge = step < 4 || step > 18
                addSprite(to: slash, color: edge ? rgb(255, 228, 128) : rgb(226, 232, 220), rect: CGRect(x: x, y: y, width: 5, height: 2), z: 1)
                if step.isMultiple(of: 2) {
                    addSprite(to: slash, color: color, rect: CGRect(x: x - facing * 2, y: y - 3, width: 4, height: 2), z: 0)
                }
            }
        case .daggers:
            for lane in 0...1 {
                for step in 0...12 {
                    let t = CGFloat(step) / 12
                    let angle = -0.65 + t * 1.3
                    let x = facing * (cos(angle) * width * 0.48 + width * (0.18 + CGFloat(lane) * 0.18))
                    let y = yOffset + CGFloat(lane * 5) + sin(angle) * height * 0.45
                    addSprite(to: slash, color: step.isMultiple(of: 3) ? rgb(229, 255, 241) : color, rect: CGRect(x: x, y: y, width: 3, height: 1), z: CGFloat(lane))
                }
            }
        case .chainWhip:
            for step in 0...18 {
                let t = CGFloat(step) / 18
                let angle = -0.92 + t * 1.84
                let x = facing * (cos(angle) * width * 0.42 + width * 0.18)
                let y = yOffset + sin(angle) * height * 0.5
                let pixel = step.isMultiple(of: 3) ? color : rgb(255, 232, 153)
                addSprite(to: slash, color: pixel, rect: CGRect(x: x, y: y, width: 3, height: 2), z: 0)
            }
        }

        effectsLayer.addChild(slash)
        slash.run(.sequence([
            .group([.scale(to: 1.22, duration: 0.08), .fadeOut(withDuration: 0.12)]),
            .removeFromParent()
        ]))
    }

    private func spawnTelegraph(from start: CGPoint, to end: CGPoint) {
        let origin = start + CGPoint(x: 0, y: 14)
        let target = end + CGPoint(x: 0, y: 12)
        let vector = CGVector(dx: target.x - origin.x, dy: target.y - origin.y)
        let length = max(1, hypot(vector.dx, vector.dy))
        let normal = CGVector(dx: -vector.dy / length, dy: vector.dx / length)
        let warning = SKNode()
        warning.zPosition = 560

        for step in 0...12 {
            let t = CGFloat(step) / 12
            let center = CGPoint(x: origin.x + vector.dx * t, y: origin.y + vector.dy * t)
            if step.isMultiple(of: 2) {
                addSprite(to: warning, color: rgb(244, 184, 65), rect: CGRect(x: center.x - 2, y: center.y - 1, width: 4, height: 2), z: 0)
                addSprite(to: warning, color: rgb(109, 70, 36), rect: CGRect(x: center.x + normal.dx * 3, y: center.y + normal.dy * 3, width: 2, height: 2), z: 1)
            }
        }
        addSprite(to: warning, color: rgb(255, 220, 105), rect: CGRect(x: target.x - 3, y: target.y - 3, width: 6, height: 2), z: 2)
        addSprite(to: warning, color: rgb(255, 220, 105), rect: CGRect(x: target.x - 1, y: target.y - 6, width: 2, height: 6), z: 2)
        effectsLayer.addChild(warning)
        warning.run(.sequence([.fadeOut(withDuration: 0.34), .removeFromParent()]))
    }

    private func spawnTelegraphCircle(at point: CGPoint, radius: CGFloat) {
        let warning = SKNode()
        warning.zPosition = 560
        let center = point + CGPoint(x: 0, y: 12)
        for step in 0..<18 {
            let angle = CGFloat(step) / 18 * .pi * 2
            let x = center.x + cos(angle) * radius
            let y = center.y + sin(angle) * radius * 0.64
            let color = step.isMultiple(of: 3) ? rgb(251, 164, 91) : rgb(224, 73, 88)
            addSprite(to: warning, color: color, rect: CGRect(x: x - 2, y: y - 2, width: 4, height: 2), z: 0)
            if step.isMultiple(of: 6) {
                addSprite(to: warning, color: rgb(255, 215, 119), rect: CGRect(x: x - 1, y: y + 1, width: 2, height: 5), z: 1)
            }
        }
        addSprite(to: warning, color: rgb(224, 73, 88), rect: CGRect(x: center.x - 5, y: center.y - 1, width: 10, height: 2), z: 2)
        addSprite(to: warning, color: rgb(224, 73, 88), rect: CGRect(x: center.x - 1, y: center.y - 5, width: 2, height: 10), z: 2)
        effectsLayer.addChild(warning)
        warning.run(.sequence([.fadeOut(withDuration: 0.34), .removeFromParent()]))
    }

    private func spawnAfterimage() {
        let ghost = playerNode.copy() as! SKSpriteNode
        ghost.children.compactMap { $0 as? SKLightNode }.forEach { $0.removeFromParent() }
        ghost.position = playerNode.position
        ghost.xScale = playerNode.xScale
        ghost.yScale = playerNode.yScale
        ghost.color = rgb(68, 195, 224)
        ghost.colorBlendFactor = 0.65
        ghost.alpha = 0.5
        ghost.name = "afterimage"
        ghost.zPosition = 250
        worldLayer.addChild(ghost)
        ghost.run(.sequence([.fadeOut(withDuration: 0.18), .removeFromParent()]))
    }

    private func addSnapshotAfterimages() {
        for index in 1...3 {
            let ghost = playerNode.copy() as! SKSpriteNode
            ghost.children.compactMap { $0 as? SKLightNode }.forEach { $0.removeFromParent() }
            ghost.position = playerNode.position + CGPoint(x: CGFloat(-13 * index), y: CGFloat(-5 * index))
            ghost.xScale = playerNode.xScale
            ghost.yScale = playerNode.yScale
            ghost.alpha = 0.32 / CGFloat(index)
            ghost.name = "afterimage"
            ghost.zPosition = 250 - CGFloat(index)
            worldLayer.addChild(ghost)
        }
    }

    private func spawnDust(at point: CGPoint) {
        spawnPixels(count: 10, at: point + CGPoint(x: 0, y: 2), color: rgb(125, 115, 93), power: 34)
    }

    private func spawnPixels(count: Int, at point: CGPoint, color: SKColor, power: CGFloat) {
        for index in 0..<count {
            let pixel = SKSpriteNode(color: color, size: CGSize(width: 2, height: 2))
            pixel.position = point
            pixel.zPosition = 620
            effectsLayer.addChild(pixel)
            let turn = CGFloat((index * 17) % max(1, count)) / CGFloat(max(1, count))
            let angle = turn * .pi * 2
            let speed = power * (0.35 + 0.65 * CGFloat((index * 7) % 11) / 10)
            let vector = CGVector(dx: cos(angle) * speed * 0.18, dy: sin(angle) * speed * 0.18)
            pixel.run(.sequence([
                .group([
                    .move(by: vector, duration: 0.24),
                    .fadeOut(withDuration: 0.24)
                ]),
                .removeFromParent()
            ]))
        }
    }

    private func spawnDamageNumber(_ amount: Int, at point: CGPoint, color: SKColor, prefix: String = "") {
        let text = SKNode()
        text.position = point
        text.zPosition = 650
        effectsLayer.addChild(text)
        addPixelText("\(prefix)\(amount)", at: .zero, scale: prefix.isEmpty ? 1.4 : 1, color: color, align: .center, to: text, z: 0)
        text.run(.sequence([
            .group([.moveBy(x: 0, y: 18, duration: 0.46), .fadeOut(withDuration: 0.46)]),
            .removeFromParent()
        ]))
    }

    private func addRuinedColumn(to parent: SKNode, color: SKColor, rect: CGRect) {
        addSprite(to: parent, color: color, rect: rect, z: 0)
        addSprite(to: parent, color: color.withAlphaComponent(0.55), rect: CGRect(x: rect.minX + 4, y: rect.maxY - 10, width: rect.width - 8, height: 3), z: 1)
        for step in stride(from: rect.minY + 12, to: rect.maxY - 8, by: 18) {
            addSprite(to: parent, color: rgb(18, 24, 29, alpha: 0.6), rect: CGRect(x: rect.minX + 5, y: step, width: rect.width - 10, height: 2), z: 2)
        }
    }

    private func addStoneTile(at point: CGPoint, moss: Bool, z: CGFloat) {
        let base = moss ? rgb(60, 82, 61) : rgb(50, 55, 58)
        addSprite(to: worldLayer, color: base, rect: CGRect(x: point.x, y: point.y, width: 16, height: 16), z: z)
        addSprite(to: worldLayer, color: rgb(78, 82, 77), rect: CGRect(x: point.x, y: point.y + 13, width: 16, height: 3), z: z + 1)
        addSprite(to: worldLayer, color: rgb(33, 36, 39), rect: CGRect(x: point.x, y: point.y, width: 16, height: 2), z: z + 1)
        if moss {
            addSprite(to: worldLayer, color: rgb(91, 122, 72), rect: CGRect(x: point.x + 2, y: point.y + 14, width: 8, height: 2), z: z + 2)
            addSprite(to: worldLayer, color: rgb(73, 103, 64), rect: CGRect(x: point.x + 11, y: point.y + 11, width: 3, height: 3), z: z + 2)
        } else {
            let seed = Int(point.x) * 41 + Int(point.y) * 23
            if deterministicInt(seed: seed, in: 0...3) == 0 {
                addSprite(
                    to: worldLayer,
                    color: rgb(33, 35, 37),
                    rect: CGRect(
                        x: point.x + CGFloat(deterministicInt(seed: seed + 1, in: 3...9)),
                        y: point.y + CGFloat(deterministicInt(seed: seed + 2, in: 5...11)),
                        width: CGFloat(deterministicInt(seed: seed + 3, in: 4...7)),
                        height: 1
                    ),
                    z: z + 2
                )
            }
        }
    }

    private func addStonePlatform(_ rect: CGRect) {
        let tileWidth: CGFloat = 16
        let visualY = rect.minY - 8
        for x in stride(from: rect.minX, to: rect.maxX, by: tileWidth) {
            let width = min(tileWidth, rect.maxX - x)
            let isLeft = x == rect.minX
            let isRight = x + tileWidth >= rect.maxX
            let asset = isLeft ? "StoneLedgeLeft" : (isRight ? "StoneLedgeRight" : "StoneLedgeTile")
            if addImage(to: worldLayer, named: asset, rect: CGRect(x: x, y: visualY, width: width, height: 20), z: 26) == nil {
                addSprite(to: worldLayer, color: rgb(47, 53, 49), rect: CGRect(x: x, y: rect.minY - 4, width: width, height: rect.height + 4), z: 26)
            } else {
                let index = Int((x - rect.minX) / tileWidth)
                if index.isMultiple(of: 2) {
                    addSprite(to: worldLayer, color: rgb(48, 74, 46), rect: CGRect(x: x + 5, y: rect.minY - 8, width: 2, height: 8), z: 25)
                }
            }
        }
    }

    private func addExitDoor(at point: CGPoint, open: Bool) {
        let frame = CGRect(x: point.x - 11, y: point.y - 1, width: 22, height: 38)
        addSprite(to: worldLayer, color: rgb(33, 30, 32), rect: frame, z: 14)
        addSprite(to: worldLayer, color: rgb(96, 90, 78), rect: CGRect(x: frame.minX - 3, y: frame.minY, width: 4, height: frame.height), z: 15)
        addSprite(to: worldLayer, color: rgb(96, 90, 78), rect: CGRect(x: frame.maxX - 1, y: frame.minY, width: 4, height: frame.height), z: 15)
        addSprite(to: worldLayer, color: open ? rgb(90, 145, 118) : rgb(77, 54, 45), rect: CGRect(x: frame.minX + 4, y: frame.minY + 4, width: 14, height: 28), z: 16)
    }

    private func addBossDoor(at point: CGPoint) {
        addExitDoor(at: point, open: false)
        let skull = SKLabelNode(fontNamed: "Menlo-Bold")
        skull.text = "☠"
        skull.fontSize = 16
        skull.fontColor = rgb(197, 74, 130)
        skull.position = CGPoint(x: point.x, y: point.y + 22)
        skull.zPosition = 30
        worldLayer.addChild(skull)
        let light = SKLightNode()
        light.categoryBitMask = 1
        light.lightColor = rgb(168, 68, 176)
        light.falloff = 2.2
        light.position = CGPoint(x: point.x, y: point.y + 22)
        worldLayer.addChild(light)
    }

    private func addForegroundRubble(isBoss: Bool) {
        let color = isBoss ? rgb(31, 17, 24, alpha: 0.82) : rgb(16, 20, 22, alpha: 0.78)
        for index in 0..<16 {
            let seed = (isBoss ? 9000 : 1200) + index * 73
            let x = CGFloat(index * 34 + deterministicInt(seed: seed, in: -7...7))
            let height = CGFloat(deterministicInt(seed: seed + 1, in: 5...18))
            addSprite(
                to: worldLayer,
                color: color,
                rect: CGRect(
                    x: x,
                    y: 0,
                    width: CGFloat(deterministicInt(seed: seed + 2, in: 14...30)),
                    height: height
                ),
                z: 120
            )
        }
    }

    private func addTorch(at point: CGPoint) {
        addSprite(to: worldLayer, color: rgb(84, 54, 38), rect: CGRect(x: point.x - 2, y: point.y - 8, width: 4, height: 9), z: 20)
        addSprite(to: worldLayer, color: rgb(124, 89, 54), rect: CGRect(x: point.x - 5, y: point.y - 2, width: 10, height: 2), z: 21)
        let flame = SKSpriteNode(color: rgb(246, 145, 59), size: CGSize(width: 6, height: 8))
        flame.position = point
        flame.zPosition = 24
        flame.lightingBitMask = 1
        addPixel(to: flame, color: rgb(255, 224, 119), rect: CGRect(x: -1, y: -1, width: 2, height: 5), z: 2)
        worldLayer.addChild(flame)
        flame.run(.repeatForever(.sequence([
            .scale(to: 1.16, duration: 0.18),
            .scale(to: 0.9, duration: 0.14)
        ])))

        let light = SKLightNode()
        light.categoryBitMask = 1
        light.lightColor = rgb(246, 148, 68)
        light.ambientColor = rgb(18, 14, 18, alpha: 0.45)
        light.shadowColor = .clear
        light.falloff = 1.35
        light.position = point
        worldLayer.addChild(light)
    }

    private func addTorchGlow(at point: CGPoint) {
        let light = SKLightNode()
        light.categoryBitMask = 1
        light.lightColor = rgb(248, 157, 74)
        light.ambientColor = rgb(19, 16, 20, alpha: 0.2)
        light.shadowColor = .clear
        light.falloff = 1.7
        light.position = point
        worldLayer.addChild(light)
    }

    @discardableResult
    private func addSprite(to parent: SKNode, color: SKColor, rect: CGRect, z: CGFloat) -> SKSpriteNode {
        let node = SKSpriteNode(color: color, size: rect.size)
        node.anchorPoint = .zero
        node.position = rect.origin
        node.zPosition = z
        node.lightingBitMask = (parent === worldLayer || parent === backgroundLayer) ? 1 : 0
        parent.addChild(node)
        return node
    }

    @discardableResult
    private func addImage(to parent: SKNode, named name: String, rect: CGRect, z: CGFloat) -> SKSpriteNode? {
        guard let texture = SpriteArt.texture(named: name) else { return nil }
        let node = SKSpriteNode(texture: texture, color: .clear, size: rect.size)
        node.anchorPoint = .zero
        node.position = rect.origin
        node.zPosition = z
        node.lightingBitMask = parent === worldLayer ? 1 : 0
        parent.addChild(node)
        return node
    }

    private func addLabel(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        color: SKColor,
        to parent: SKNode,
        align: SKLabelHorizontalAlignmentMode = .center
    ) {
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = text
        label.fontSize = size
        label.fontColor = color
        label.horizontalAlignmentMode = align
        label.verticalAlignmentMode = .center
        label.position = point
        label.zPosition = 900
        parent.addChild(label)
    }

    private func addPixelText(
        _ text: String,
        at point: CGPoint,
        scale: CGFloat,
        color: SKColor,
        align: SKLabelHorizontalAlignmentMode,
        to parent: SKNode? = nil,
        z: CGFloat = 900
    ) {
        let text = text.uppercased()
        let parent = parent ?? hudLayer
        let width = pixelTextWidth(text, scale: scale)
        let originX = switch align {
        case .left: point.x
        case .right: point.x - width
        default: point.x - width / 2
        }
        var cursor = originX
        for char in text {
            if char == " " {
                cursor += 4 * scale
                continue
            }
            let glyph = pixelGlyphs[char] ?? pixelGlyphs["?"]!
            for (rowIndex, row) in glyph.enumerated() {
                for (columnIndex, pixel) in row.enumerated() where pixel == "1" {
                    addSprite(
                        to: parent,
                        color: color,
                        rect: CGRect(
                            x: cursor + CGFloat(columnIndex) * scale,
                            y: point.y + CGFloat(glyph.count - rowIndex) * scale,
                            width: scale,
                            height: scale
                        ),
                        z: z
                    )
                }
            }
            cursor += 6 * scale
        }
    }

    private func pixelTextWidth(_ text: String, scale: CGFloat) -> CGFloat {
        text.uppercased().reduce(CGFloat.zero) { width, char in
            width + (char == " " ? 4 * scale : 6 * scale)
        }
    }

    private func addOpaquePanel(rect: CGRect) {
        if addImage(to: hudLayer, named: "HUDModalPanel", rect: rect, z: 810) != nil {
            return
        }
        addSprite(to: hudLayer, color: rgb(13, 12, 14), rect: rect, z: 810)
        addSprite(to: hudLayer, color: rgb(16, 14, 15), rect: rect.insetBy(dx: 5, dy: 5), z: 811)

        addSprite(to: hudLayer, color: rgb(96, 88, 73), rect: CGRect(x: rect.minX, y: rect.maxY - 5, width: rect.width, height: 5), z: 812)
        addSprite(to: hudLayer, color: rgb(39, 34, 32), rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 4), z: 812)
        addSprite(to: hudLayer, color: rgb(71, 63, 55), rect: CGRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height), z: 812)
        addSprite(to: hudLayer, color: rgb(71, 63, 55), rect: CGRect(x: rect.maxX - 4, y: rect.minY, width: 4, height: rect.height), z: 812)

        for x in stride(from: rect.minX + 10, to: rect.maxX - 14, by: 18) {
            addSprite(to: hudLayer, color: rgb(50, 45, 41), rect: CGRect(x: x, y: rect.maxY - 3, width: 10, height: 2), z: 813)
            addSprite(to: hudLayer, color: rgb(25, 22, 23), rect: CGRect(x: x + 5, y: rect.minY + 2, width: 9, height: 2), z: 813)
        }

        addSprite(to: hudLayer, color: rgb(220, 162, 72), rect: CGRect(x: rect.minX + 6, y: rect.maxY - 8, width: 9, height: 2), z: 814)
        addSprite(to: hudLayer, color: rgb(220, 162, 72), rect: CGRect(x: rect.maxX - 15, y: rect.maxY - 8, width: 9, height: 2), z: 814)
        addSprite(to: hudLayer, color: rgb(123, 93, 54), rect: CGRect(x: rect.minX + 6, y: rect.minY + 5, width: 9, height: 2), z: 814)
        addSprite(to: hudLayer, color: rgb(123, 93, 54), rect: CGRect(x: rect.maxX - 15, y: rect.minY + 5, width: 9, height: 2), z: 814)
    }

    private func mappedActions(for event: NSEvent) -> [InputAction] {
        switch event.keyCode {
        case 0, 123: return [.left]
        case 2, 124: return [.right]
        case 13, 126: return [.up, .jump]
        case 1, 125: return [.down]
        case 49: return [.jump]
        case 36: return [.restart]
        case 48: return [.switchWeapon]
        case 18: return [.slot1]
        case 19: return [.slot2]
        case 20: return [.slot3]
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j", "x": return [.attack]
        case "k": return [.dash]
        case "r": return [.restart]
        default: return []
        }
    }

    private func isPauseEvent(_ event: NSEvent) -> Bool {
        event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "p"
    }

    private func pollGamepad() {
        guard let pad = GCController.controllers().first?.extendedGamepad else {
            input.clearGamepad()
            return
        }
        let horizontal = pad.leftThumbstick.xAxis.value + pad.dpad.xAxis.value
        let vertical = pad.leftThumbstick.yAxis.value + pad.dpad.yAxis.value
        input.setGamepad(.left, isDown: horizontal < -0.25)
        input.setGamepad(.right, isDown: horizontal > 0.25)
        input.setGamepad(.up, isDown: vertical > 0.35)
        input.setGamepad(.down, isDown: vertical < -0.35)
        input.setGamepad(.jump, isDown: pad.buttonA.isPressed)
        input.setGamepad(.dash, isDown: pad.buttonB.isPressed)
        input.setGamepad(.attack, isDown: pad.buttonX.isPressed)
        input.setGamepad(.switchWeapon, isDown: pad.rightShoulder.isPressed)
        input.setGamepad(.restart, isDown: pad.buttonY.isPressed)
    }
}

private func basePlatforms(_ extra: [CGRect]) -> [CGRect] {
    [CGRect(x: 0, y: 30, width: 480, height: 14)] + extra
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> SKColor {
    SKColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
}

private func approach(_ value: CGFloat, _ target: CGFloat, by amount: CGFloat) -> CGFloat {
    if value < target {
        min(value + amount, target)
    } else {
        max(value - amount, target)
    }
}

private func deterministicInt(seed: Int, in range: ClosedRange<Int>) -> Int {
    let span = UInt64(range.upperBound - range.lowerBound + 1)
    var value = UInt64(bitPattern: Int64(seed))
    value ^= value >> 30
    value &*= 0xbf58476d1ce4e5b9
    value ^= value >> 27
    value &*= 0x94d049bb133111eb
    value ^= value >> 31
    return range.lowerBound + Int(value % span)
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func argumentValue(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
    let valueIndex = CommandLine.arguments.index(after: index)
    guard CommandLine.arguments.indices.contains(valueIndex) else { return nil }
    return CommandLine.arguments[valueIndex]
}

private func scenePNGData(from texture: SKTexture) -> Data? {
    let image = NSImage(cgImage: texture.cgImage(), size: texture.size())
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}

@MainActor
private enum SpriteArt {
    private static var cache = [String: SKTexture]()

    static func texture(named name: String) -> SKTexture? {
        if let cached = cache[name] {
            return cached
        }
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest
        cache[name] = texture
        return texture
    }
}

@MainActor
private func addPixel(to parent: SKNode, color: SKColor, rect: CGRect, z: CGFloat) {
    let pixel = SKSpriteNode(color: color, size: rect.size)
    pixel.anchorPoint = .zero
    pixel.position = rect.origin
    pixel.zPosition = z
    pixel.lightingBitMask = 1
    parent.addChild(pixel)
}

@MainActor
private func decorateEnemyNode(_ node: SKSpriteNode, kind: EnemyKind, size: CGSize) {
    switch kind {
    case .skeleton:
        addPixel(to: node, color: rgb(239, 232, 198), rect: CGRect(x: -5, y: 16, width: 10, height: 6), z: 4)
        addPixel(to: node, color: rgb(186, 176, 141), rect: CGRect(x: -4, y: 14, width: 8, height: 3), z: 3)
        addPixel(to: node, color: rgb(28, 25, 25), rect: CGRect(x: -3, y: 18, width: 2, height: 2), z: 5)
        addPixel(to: node, color: rgb(28, 25, 25), rect: CGRect(x: 2, y: 18, width: 2, height: 2), z: 5)
        addPixel(to: node, color: rgb(224, 216, 180), rect: CGRect(x: -5, y: 10, width: 10, height: 2), z: 4)
        for rib in 0..<3 {
            addPixel(to: node, color: rgb(215, 207, 174), rect: CGRect(x: -4, y: 6 + rib * 2, width: 8, height: 1), z: 4)
        }
        addPixel(to: node, color: rgb(198, 190, 158), rect: CGRect(x: -4, y: 1, width: 2, height: 8), z: 3)
        addPixel(to: node, color: rgb(198, 190, 158), rect: CGRect(x: 3, y: 1, width: 2, height: 8), z: 3)
        addPixel(to: node, color: rgb(128, 94, 64), rect: CGRect(x: -9, y: 6, width: 2, height: 15), z: 4)
        addPixel(to: node, color: rgb(202, 195, 161), rect: CGRect(x: -10, y: 19, width: 4, height: 2), z: 5)
        addPixel(to: node, color: rgb(78, 70, 61), rect: CGRect(x: 6, y: 7, width: 6, height: 8), z: 5)
        addPixel(to: node, color: rgb(136, 124, 99), rect: CGRect(x: 7, y: 12, width: 4, height: 2), z: 6)
    case .archer:
        addPixel(to: node, color: rgb(31, 51, 41), rect: CGRect(x: -6, y: 9, width: 12, height: 10), z: 3)
        addPixel(to: node, color: rgb(77, 111, 77), rect: CGRect(x: -5, y: 12, width: 10, height: 7), z: 4)
        addPixel(to: node, color: rgb(19, 29, 26), rect: CGRect(x: -4, y: 16, width: 8, height: 4), z: 5)
        addPixel(to: node, color: rgb(213, 203, 166), rect: CGRect(x: -2, y: 15, width: 4, height: 2), z: 6)
        addPixel(to: node, color: rgb(50, 78, 55), rect: CGRect(x: -5, y: 2, width: 10, height: 8), z: 3)
        addPixel(to: node, color: rgb(20, 25, 22), rect: CGRect(x: -4, y: 0, width: 3, height: 4), z: 4)
        addPixel(to: node, color: rgb(20, 25, 22), rect: CGRect(x: 2, y: 0, width: 3, height: 4), z: 4)
        addPixel(to: node, color: rgb(107, 76, 42), rect: CGRect(x: 7, y: 3, width: 2, height: 16), z: 5)
        addPixel(to: node, color: rgb(228, 203, 112), rect: CGRect(x: 7, y: 11, width: 10, height: 1), z: 6)
        addPixel(to: node, color: rgb(228, 203, 112), rect: CGRect(x: 12, y: 9, width: 1, height: 5), z: 6)
    case .exploder:
        addPixel(to: node, color: rgb(92, 37, 36), rect: CGRect(x: -7, y: 3, width: 14, height: 10), z: 3)
        addPixel(to: node, color: rgb(137, 54, 43), rect: CGRect(x: -5, y: 1, width: 10, height: 14), z: 4)
        addPixel(to: node, color: rgb(247, 128, 64), rect: CGRect(x: -3, y: 7, width: 7, height: 5), z: 5)
        addPixel(to: node, color: rgb(255, 219, 98), rect: CGRect(x: -1, y: 8, width: 3, height: 3), z: 6)
        addPixel(to: node, color: rgb(252, 213, 95), rect: CGRect(x: 0, y: 14, width: 2, height: 5), z: 5)
        addPixel(to: node, color: rgb(36, 27, 28), rect: CGRect(x: -3, y: 11, width: 1, height: 1), z: 6)
        addPixel(to: node, color: rgb(36, 27, 28), rect: CGRect(x: 4, y: 11, width: 1, height: 1), z: 6)
    case .boss:
        addPixel(to: node, color: rgb(43, 18, 30), rect: CGRect(x: -16, y: 8, width: 9, height: 25), z: 2)
        addPixel(to: node, color: rgb(43, 18, 30), rect: CGRect(x: 7, y: 8, width: 9, height: 25), z: 2)
        addPixel(to: node, color: rgb(61, 22, 38), rect: CGRect(x: -10, y: 5, width: 20, height: 31), z: 3)
        addPixel(to: node, color: rgb(94, 32, 55), rect: CGRect(x: -13, y: 13, width: 26, height: 16), z: 4)
        addPixel(to: node, color: rgb(24, 16, 22), rect: CGRect(x: -16, y: 3, width: 7, height: 7), z: 4)
        addPixel(to: node, color: rgb(24, 16, 22), rect: CGRect(x: 9, y: 3, width: 7, height: 7), z: 4)
        addPixel(to: node, color: rgb(225, 218, 184), rect: CGRect(x: -11, y: 31, width: 22, height: 12), z: 5)
        addPixel(to: node, color: rgb(184, 176, 142), rect: CGRect(x: -8, y: 27, width: 16, height: 5), z: 4)
        addPixel(to: node, color: rgb(23, 18, 22), rect: CGRect(x: -6, y: 35, width: 3, height: 3), z: 6)
        addPixel(to: node, color: rgb(23, 18, 22), rect: CGRect(x: 4, y: 35, width: 3, height: 3), z: 6)
        addPixel(to: node, color: rgb(239, 89, 143), rect: CGRect(x: -19, y: 43, width: 8, height: 4), z: 6)
        addPixel(to: node, color: rgb(239, 89, 143), rect: CGRect(x: 11, y: 43, width: 8, height: 4), z: 6)
        addPixel(to: node, color: rgb(167, 54, 92), rect: CGRect(x: -17, y: 20, width: 34, height: 7), z: 5)
        addPixel(to: node, color: rgb(238, 95, 145), rect: CGRect(x: -14, y: 23, width: 28, height: 2), z: 6)
        addPixel(to: node, color: rgb(229, 207, 139), rect: CGRect(x: -18, y: 18, width: 8, height: 3), z: 6)
        addPixel(to: node, color: rgb(230, 197, 123), rect: CGRect(x: 16, y: 11, width: 4, height: 26), z: 6)
        addPixel(to: node, color: rgb(98, 73, 58), rect: CGRect(x: 13, y: 8, width: 10, height: 8), z: 6)
        addPixel(to: node, color: rgb(230, 197, 123), rect: CGRect(x: -20, y: 11, width: 4, height: 18), z: 6)
        addPixel(to: node, color: rgb(98, 73, 58), rect: CGRect(x: -23, y: 8, width: 10, height: 8), z: 6)
    }
}

private let pixelGlyphs: [Character: [String]] = [
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01111", "10000", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "J": ["00111", "00010", "00010", "00010", "10010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["10010", "10010", "10010", "11111", "00010", "00010", "00010"],
    "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
    "6": ["01111", "10000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00001", "11110"],
    "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
    "=": ["00000", "11111", "00000", "00000", "11111", "00000", "00000"],
    "?": ["01110", "10001", "00001", "00010", "00100", "00000", "00100"]
]

private final class ToneSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
        player.play()
    }

    func playHit(weight: CGFloat) {
        tone(frequency: Double.random(in: 150...210) + Double(weight * 24), duration: 0.07, gain: 0.20)
    }

    func playDash() {
        tone(frequency: Double.random(in: 420...520), duration: 0.045, gain: 0.12)
    }

    func playJump() {
        tone(frequency: Double.random(in: 260...330), duration: 0.055, gain: 0.10)
    }

    func playHurt() {
        tone(frequency: Double.random(in: 90...130), duration: 0.09, gain: 0.22)
    }

    func playParry() {
        tone(frequency: Double.random(in: 620...740), duration: 0.08, gain: 0.16)
    }

    func playExplosion() {
        tone(frequency: Double.random(in: 60...90), duration: 0.14, gain: 0.26)
    }

    private func tone(frequency: Double, duration: Double, gain: Float) {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(format.sampleRate * duration)
        ) else { return }

        buffer.frameLength = buffer.frameCapacity
        guard let channel = buffer.floatChannelData?[0] else { return }
        for frame in 0..<Int(buffer.frameLength) {
            let t = Double(frame) / format.sampleRate
            let envelope = Float(max(0, 1 - t / duration))
            let jitter = Double.random(in: -0.018...0.018)
            let sample = sin((t + jitter) * frequency * Double.pi * 2)
            channel[frame] = Float(sample) * gain * envelope
        }

        if !engine.isRunning {
            try? engine.start()
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }
}
