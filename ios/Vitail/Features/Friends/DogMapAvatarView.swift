import SwiftUI

struct DogMapAvatarView: View {
    let breed: DogMapBreed
    let bandanaColor: DogBandanaColor
    let outfit: DogAvatarOutfit
    private let outline = Color(red: 0.29, green: 0.22, blue: 0.18)

    init(breed: DogMapBreed, bandanaColor: DogBandanaColor, outfit: DogAvatarOutfit = .plain) {
        self.breed = breed
        self.bandanaColor = bandanaColor
        self.outfit = outfit
    }

    private var coat: Color {
        switch breed {
        case .goldenRetriever: return Color(red: 0.93, green: 0.67, blue: 0.31)
        case .corgi: return Color(red: 0.88, green: 0.49, blue: 0.23)
        case .husky: return Color(red: 0.40, green: 0.48, blue: 0.57)
        case .dalmatian: return Color(red: 0.98, green: 0.97, blue: 0.93)
        case .beagle: return Color(red: 0.76, green: 0.44, blue: 0.22)
        case .shiba: return Color(red: 0.91, green: 0.47, blue: 0.20)
        case .poodle: return Color(red: 0.88, green: 0.76, blue: 0.61)
        case .dachshund: return Color(red: 0.46, green: 0.25, blue: 0.13)
        case .cat: return Color(red: 0.66, green: 0.70, blue: 0.76)
        }
    }

    private var headShape: DogAvatarVectorShape.Part {
        switch breed {
        case .cat: return .catHead
        case .dachshund: return .houndHead
        default: return .head
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let canvasSide = min(geometry.size.width, geometry.size.height)
            let side = canvasSide * (outfit.hat == .none ? 1 : 0.78)
            ZStack {
                if bandanaColor != .none {
                    DogAvatarVectorShape(part: .bandana)
                        .fill(bandanaColor.avatarColor)
                    DogAvatarVectorShape(part: .bandana)
                        .stroke(outline.opacity(0.6), lineWidth: side * 0.018)
                    bandanaPattern(side: side)
                }
                ears(side: side)
                DogAvatarVectorShape(part: headShape).fill(coat)
                DogAvatarVectorShape(part: headShape).stroke(outline, lineWidth: side * 0.02)
                faceMarkings(side: side)
                muzzle(side: side)
                facialFeatures(side: side)
                decoration(side: side)
                hat(side: side)
                if bandanaColor != .none {
                    Capsule()
                        .fill(bandanaColor.avatarColor)
                        .frame(width: side * 0.43, height: side * 0.065)
                        .position(x: side * 0.5, y: side * 0.795)
                    Circle().fill(Color.white.opacity(0.45))
                        .frame(width: side * 0.045, height: side * 0.045)
                        .position(x: side * 0.47, y: side * 0.88)
                    Circle().fill(Color.white.opacity(0.45))
                        .frame(width: side * 0.028, height: side * 0.028)
                        .position(x: side * 0.54, y: side * 0.91)
                }
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2,
                      y: geometry.size.height / 2 + (outfit.hat == .none ? 0 : canvasSide * 0.085))
        }
        .accessibilityLabel((bandanaColor == .none
                            ? "\(breed.title), no scarf, no designation"
                            : "\(breed.title) wearing a \(bandanaColor.title.lowercased()) bandana, \(bandanaColor.guidance ?? "")") + wearableDescription)
    }

    private var wearableDescription: String {
        var descriptions: [String] = []
        switch outfit.hat {
        case .none: break
        case .baseballCap: descriptions.append("baseball cap")
        case .beanie: descriptions.append("cosy beanie")
        case .sunHat: descriptions.append("sun hat")
        }
        if bandanaColor != .none {
            switch outfit.bandanaStyle {
            case .classic: break
            case .striped: descriptions.append("striped bandana")
            case .polkaDot: descriptions.append("polka-dot bandana")
            }
        }
        switch outfit.decoration {
        case .none: break
        case .roundGlasses: descriptions.append("round glasses")
        case .starBadge: descriptions.append("star badge")
        }
        return descriptions.isEmpty ? "" : ", " + descriptions.joined(separator: ", ")
    }

    @ViewBuilder private func bandanaPattern(side: CGFloat) -> some View {
        if outfit.bandanaStyle == .striped {
            ZStack {
                ForEach(0..<5, id: \.self) { stripe in
                    Capsule().fill(Color.white.opacity(0.43))
                        .frame(width: side * 0.75, height: side * 0.025)
                        .rotationEffect(.degrees(-22))
                        .position(x: side * 0.5, y: side * (0.72 + Double(stripe) * 0.063))
                }
            }
            .frame(width: side, height: side)
            .clipShape(DogAvatarVectorShape(part: .bandana))
        } else if outfit.bandanaStyle == .polkaDot {
            ZStack {
                ForEach(0..<9, id: \.self) { dot in
                    Circle().fill(Color.white.opacity(0.67))
                        .frame(width: side * 0.035, height: side * 0.035)
                        .position(x: side * (0.34 + Double(dot % 3) * 0.16),
                                  y: side * (0.79 + Double(dot / 3) * 0.07))
                }
            }
            .frame(width: side, height: side)
            .clipShape(DogAvatarVectorShape(part: .bandana))
        }
    }

    @ViewBuilder private func hat(side: CGFloat) -> some View {
        switch outfit.hat {
        case .none:
            EmptyView()
        case .baseballCap:
            DogAvatarVectorShape(part: .capCrown)
                .fill(Color(red: 0.20, green: 0.43, blue: 0.70))
                .overlay { DogAvatarVectorShape(part: .capCrown).stroke(outline, lineWidth: side * 0.018) }
            DogAvatarVectorShape(part: .capBrim)
                .fill(Color(red: 0.11, green: 0.29, blue: 0.53))
                .overlay { DogAvatarVectorShape(part: .capBrim).stroke(outline, lineWidth: side * 0.018) }
            Capsule().fill(Color.white.opacity(0.70))
                .frame(width: side * 0.035, height: side * 0.10)
                .position(x: side * 0.50, y: side * 0.035)
        case .beanie:
            Ellipse().fill(Color(red: 0.57, green: 0.33, blue: 0.53))
                .overlay { Ellipse().stroke(outline, lineWidth: side * 0.018) }
                .frame(width: side * 0.64, height: side * 0.29)
                .position(x: side * 0.50, y: side * 0.02)
            Capsule().fill(Color(red: 0.70, green: 0.47, blue: 0.65))
                .overlay { Capsule().stroke(outline, lineWidth: side * 0.015) }
                .frame(width: side * 0.69, height: side * 0.085)
                .position(x: side * 0.50, y: side * 0.145)
            Circle().fill(Color(red: 0.80, green: 0.60, blue: 0.73))
                .overlay { Circle().stroke(outline, lineWidth: side * 0.015) }
                .frame(width: side * 0.11, height: side * 0.11)
                .position(x: side * 0.50, y: side * -0.135)
        case .sunHat:
            RoundedRectangle(cornerRadius: side * 0.07)
                .fill(Color(red: 0.94, green: 0.79, blue: 0.48))
                .overlay { RoundedRectangle(cornerRadius: side * 0.07).stroke(outline, lineWidth: side * 0.018) }
                .frame(width: side * 0.46, height: side * 0.23)
                .position(x: side * 0.50, y: side * 0.035)
            Capsule().fill(Color(red: 0.68, green: 0.39, blue: 0.20))
                .frame(width: side * 0.47, height: side * 0.055)
                .position(x: side * 0.50, y: side * 0.095)
            Ellipse().fill(Color(red: 0.98, green: 0.85, blue: 0.58))
                .overlay { Ellipse().stroke(outline, lineWidth: side * 0.018) }
                .frame(width: side * 0.94, height: side * 0.13)
                .position(x: side * 0.50, y: side * 0.155)
        }
    }

    @ViewBuilder private func decoration(side: CGFloat) -> some View {
        switch outfit.decoration {
        case .none:
            EmptyView()
        case .roundGlasses:
            ForEach([0.34, 0.66], id: \.self) { x in
                Circle().fill(Color.blue.opacity(0.08))
                    .overlay { Circle().stroke(outline, lineWidth: side * 0.020) }
                    .frame(width: side * 0.23, height: side * 0.23)
                    .position(x: side * x, y: side * 0.46)
            }
            Path { path in
                path.move(to: CGPoint(x: side * 0.455, y: side * 0.46))
                path.addQuadCurve(to: CGPoint(x: side * 0.545, y: side * 0.46), control: CGPoint(x: side * 0.50, y: side * 0.42))
                path.move(to: CGPoint(x: side * 0.17, y: side * 0.42))
                path.addLine(to: CGPoint(x: side * 0.225, y: side * 0.46))
                path.move(to: CGPoint(x: side * 0.775, y: side * 0.46))
                path.addLine(to: CGPoint(x: side * 0.83, y: side * 0.42))
            }.stroke(outline, style: StrokeStyle(lineWidth: side * 0.020, lineCap: .round))
        case .starBadge:
            Circle().fill(Color(red: 0.98, green: 0.84, blue: 0.40))
                .overlay { Circle().stroke(outline.opacity(0.75), lineWidth: side * 0.012) }
                .frame(width: side * 0.17, height: side * 0.17)
                .position(x: side * 0.77, y: side * 0.71)
            Image(systemName: "star.fill").font(.system(size: side * 0.115))
                .foregroundStyle(Color(red: 0.67, green: 0.36, blue: 0.10))
                .position(x: side * 0.77, y: side * 0.71)
        }
    }

    @ViewBuilder private func ears(side: CGFloat) -> some View {
        if breed == .corgi || breed == .husky || breed == .shiba || breed == .cat {
            ForEach([false, true], id: \.self) { mirrored in
                DogAvatarVectorShape(part: .pointedEar, mirrored: mirrored).fill(coat)
                DogAvatarVectorShape(part: .pointedEar, mirrored: mirrored)
                    .stroke(outline, lineWidth: side * 0.02)
                DogAvatarVectorShape(part: .innerEar, mirrored: mirrored)
                    .fill(Color(red: 0.92, green: 0.65, blue: 0.64))
            }
        } else if breed == .poodle {
            ForEach([false, true], id: \.self) { mirrored in
                ForEach(0..<5, id: \.self) { curl in
                    Circle().fill(coat)
                        .overlay { Circle().stroke(outline.opacity(0.8), lineWidth: side * 0.015) }
                        .frame(width: side * 0.21, height: side * 0.21)
                        .position(x: side * (mirrored ? 0.86 - (curl % 2 == 0 ? 0 : 0.03) : 0.14 + (curl % 2 == 0 ? 0 : 0.03)),
                                  y: side * (0.31 + Double(curl) * 0.072))
                }
            }
        } else {
            ForEach([false, true], id: \.self) { mirrored in
                DogAvatarVectorShape(part: breed == .dachshund ? .droopyEar : .floppyEar, mirrored: mirrored)
                    .fill(breed == .dalmatian && !mirrored ? outline :
                          breed == .beagle || breed == .dachshund ? coat.opacity(0.92) : coat)
                DogAvatarVectorShape(part: breed == .dachshund ? .droopyEar : .floppyEar, mirrored: mirrored)
                    .stroke(outline, lineWidth: side * 0.02)
            }
        }
    }

    @ViewBuilder private func faceMarkings(side: CGFloat) -> some View {
        if breed == .husky {
            Ellipse().fill(Color.white)
                .frame(width: side * 0.29, height: side * 0.39)
                .rotationEffect(.degrees(-20))
                .position(x: side * 0.34, y: side * 0.48)
            Ellipse().fill(Color.white)
                .frame(width: side * 0.29, height: side * 0.39)
                .rotationEffect(.degrees(20))
                .position(x: side * 0.66, y: side * 0.48)
        } else if breed == .corgi {
            Ellipse().fill(Color.white.opacity(0.95))
                .frame(width: side * 0.16, height: side * 0.43)
                .position(x: side * 0.50, y: side * 0.44)
        } else if breed == .dalmatian {
            Ellipse().fill(outline)
                .frame(width: side * 0.24, height: side * 0.23)
                .rotationEffect(.degrees(-22))
                .position(x: side * 0.32, y: side * 0.44)
            Ellipse().fill(outline)
                .frame(width: side * 0.105, height: side * 0.07)
                .rotationEffect(.degrees(20))
                .position(x: side * 0.61, y: side * 0.28)
            Circle().fill(outline).frame(width: side * 0.065, height: side * 0.065)
                .position(x: side * 0.76, y: side * 0.59)
        } else if breed == .beagle {
            ForEach([0.31, 0.69], id: \.self) { x in
                Ellipse().fill(outline.opacity(0.88))
                    .frame(width: side * 0.25, height: side * 0.20)
                    .position(x: side * x, y: side * 0.34)
            }
            Ellipse().fill(Color.white)
                .frame(width: side * 0.14, height: side * 0.42)
                .position(x: side * 0.50, y: side * 0.44)
        } else if breed == .shiba {
            ForEach([0.29, 0.71], id: \.self) { x in
                Ellipse().fill(Color(red: 1, green: 0.94, blue: 0.81))
                    .frame(width: side * 0.25, height: side * 0.25)
                    .position(x: side * x, y: side * 0.59)
                Capsule().fill(Color(red: 1, green: 0.94, blue: 0.81))
                    .frame(width: side * 0.12, height: side * 0.05)
                    .position(x: side * x, y: side * 0.36)
            }
        } else if breed == .poodle {
            ForEach(0..<5, id: \.self) { curl in
                Circle().fill(coat)
                    .overlay { Circle().stroke(outline.opacity(0.6), lineWidth: side * 0.012) }
                    .frame(width: side * 0.16, height: side * 0.16)
                    .position(x: side * (0.27 + Double(curl) * 0.115),
                              y: side * (curl % 2 == 0 ? 0.23 : 0.195))
            }
        } else if breed == .dachshund {
            ForEach([0.34, 0.66], id: \.self) { x in
                Capsule().fill(Color(red: 0.91, green: 0.64, blue: 0.33))
                    .frame(width: side * 0.12, height: side * 0.055)
                    .position(x: side * x, y: side * 0.37)
            }
        } else if breed == .cat {
            ForEach([0.40, 0.50, 0.60], id: \.self) { x in
                Capsule().fill(outline.opacity(0.55))
                    .frame(width: side * 0.045, height: side * (x == 0.50 ? 0.15 : 0.10))
                    .position(x: side * x, y: side * 0.28)
            }
        }
    }

    private func muzzle(side: CGFloat) -> some View {
        ZStack {
            Ellipse().fill(Color(red: 1, green: 0.94, blue: 0.81))
                .frame(width: side * (breed == .dachshund ? 0.43 : breed == .cat ? 0.40 : 0.55),
                       height: side * (breed == .dachshund ? 0.38 : breed == .cat ? 0.20 : 0.29))
                .position(x: side * 0.5, y: side * (breed == .dachshund ? 0.61 : 0.645))
            Ellipse().fill(Color.white.opacity(0.48))
                .frame(width: side * 0.22, height: side * 0.13)
                .position(x: side * 0.39, y: side * 0.615)
            Ellipse().fill(Color.white.opacity(0.48))
                .frame(width: side * 0.22, height: side * 0.13)
                .position(x: side * 0.61, y: side * 0.615)
        }
    }

    private func facialFeatures(side: CGFloat) -> some View {
        ZStack {
            if breed == .cat {
                ForEach([false, true], id: \.self) { mirrored in
                    DogAvatarVectorShape(part: .catEye, mirrored: mirrored)
                        .fill(Color(red: 0.48, green: 0.78, blue: 0.41))
                    DogAvatarVectorShape(part: .catEye, mirrored: mirrored)
                        .stroke(outline, lineWidth: side * 0.016)
                    Ellipse().fill(outline)
                        .frame(width: side * 0.028, height: side * 0.075)
                        .position(x: side * (mirrored ? 0.665 : 0.335), y: side * 0.46)
                }
                DogAvatarVectorShape(part: .catNose)
                    .fill(Color(red: 0.91, green: 0.48, blue: 0.57))
                Path { path in
                    for direction in [-1.0, 1.0] {
                        for line in 0..<3 {
                            let y = 0.60 + Double(line) * 0.045
                            path.move(to: CGPoint(x: side * (0.50 + direction * 0.15), y: side * y))
                            path.addLine(to: CGPoint(x: side * (0.50 + direction * 0.42),
                                                    y: side * (y + Double(line - 1) * 0.025)))
                        }
                    }
                }.stroke(outline, style: StrokeStyle(lineWidth: side * 0.013, lineCap: .round))
            } else {
                ForEach([0.34, 0.66], id: \.self) { x in
                    Ellipse().fill(breed == .husky ? Color(red: 0.14, green: 0.53, blue: 0.77) : outline)
                        .frame(width: side * 0.074, height: side * 0.10)
                        .position(x: side * x, y: side * 0.46)
                    Circle().fill(.white)
                        .frame(width: side * 0.026, height: side * 0.026)
                        .position(x: side * (x - 0.008), y: side * 0.435)
                }
                Ellipse().fill(outline)
                    .frame(width: side * 0.16, height: side * 0.10)
                    .position(x: side * 0.5, y: side * 0.59)
            }
            Path { path in
                path.move(to: CGPoint(x: side * 0.5, y: side * 0.625))
                path.addLine(to: CGPoint(x: side * 0.5, y: side * 0.66))
                path.addQuadCurve(to: CGPoint(x: side * 0.39, y: side * 0.68),
                                  control: CGPoint(x: side * 0.43, y: side * 0.72))
                path.move(to: CGPoint(x: side * 0.5, y: side * 0.66))
                path.addQuadCurve(to: CGPoint(x: side * 0.61, y: side * 0.68),
                                  control: CGPoint(x: side * 0.57, y: side * 0.72))
            }.stroke(outline, style: StrokeStyle(lineWidth: side * 0.022, lineCap: .round))
        }
    }
}

private struct DogAvatarVectorShape: Shape {
    enum Part { case head, catHead, houndHead, floppyEar, droopyEar, pointedEar, innerEar, bandana, catEye, catNose, capCrown, capBrim }
    let part: Part
    var mirrored = false

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (mirrored ? 1 - x : x) * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        switch part {
        case .capCrown:
            path.move(to: point(0.20, 0.15))
            path.addCurve(to: point(0.80, 0.15), control1: point(0.20, -0.15), control2: point(0.80, -0.15))
        case .capBrim:
            path.move(to: point(0.31, 0.13))
            path.addQuadCurve(to: point(0.94, 0.19), control: point(0.68, 0.085))
            path.addQuadCurve(to: point(0.31, 0.20), control: point(0.74, 0.27))
        case .catHead:
            path.move(to: point(0.21, 0.29))
            path.addQuadCurve(to: point(0.79, 0.29), control: point(0.50, 0.14))
            path.addCurve(to: point(0.69, 0.70), control1: point(0.93, 0.43), control2: point(0.85, 0.64))
            path.addQuadCurve(to: point(0.31, 0.70), control: point(0.50, 0.86))
            path.addCurve(to: point(0.21, 0.29), control1: point(0.15, 0.64), control2: point(0.07, 0.43))
        case .houndHead:
            path.move(to: point(0.24, 0.31))
            path.addCurve(to: point(0.76, 0.31), control1: point(0.30, 0.14), control2: point(0.70, 0.14))
            path.addCurve(to: point(0.63, 0.72), control1: point(0.81, 0.50), control2: point(0.74, 0.69))
            path.addQuadCurve(to: point(0.37, 0.72), control: point(0.50, 0.85))
            path.addCurve(to: point(0.24, 0.31), control1: point(0.26, 0.69), control2: point(0.19, 0.50))
        case .head:
            path.move(to: point(0.20, 0.32))
            path.addCurve(to: point(0.80, 0.32), control1: point(0.23, 0.09), control2: point(0.77, 0.09))
            path.addCurve(to: point(0.69, 0.73), control1: point(0.91, 0.49), control2: point(0.87, 0.69))
            path.addQuadCurve(to: point(0.31, 0.73), control: point(0.50, 0.85))
            path.addCurve(to: point(0.20, 0.32), control1: point(0.13, 0.69), control2: point(0.09, 0.49))
        case .floppyEar:
            path.move(to: point(0.24, 0.24))
            path.addCurve(to: point(0.08, 0.66), control1: point(0.05, 0.17), control2: point(0.00, 0.48))
            path.addCurve(to: point(0.26, 0.58), control1: point(0.14, 0.83), control2: point(0.28, 0.68))
            path.addQuadCurve(to: point(0.24, 0.24), control: point(0.33, 0.31))
        case .droopyEar:
            path.move(to: point(0.26, 0.26))
            path.addCurve(to: point(0.08, 0.72), control1: point(0.05, 0.17), control2: point(0.035, 0.56))
            path.addCurve(to: point(0.24, 0.74), control1: point(0.09, 0.91), control2: point(0.23, 0.91))
            path.addQuadCurve(to: point(0.26, 0.26), control: point(0.31, 0.43))
        case .pointedEar:
            path.move(to: point(0.14, 0.39))
            path.addQuadCurve(to: point(0.10, 0.045), control: point(0.065, 0.16))
            path.addQuadCurve(to: point(0.39, 0.23), control: point(0.21, 0.045))
        case .innerEar:
            path.move(to: point(0.17, 0.31))
            path.addLine(to: point(0.14, 0.11))
            path.addLine(to: point(0.31, 0.23))
        case .catEye:
            path.move(to: point(0.255, 0.46))
            path.addQuadCurve(to: point(0.415, 0.46), control: point(0.335, 0.35))
            path.addQuadCurve(to: point(0.255, 0.46), control: point(0.335, 0.535))
        case .catNose:
            path.move(to: point(0.435, 0.565))
            path.addQuadCurve(to: point(0.565, 0.565), control: point(0.50, 0.54))
            path.addQuadCurve(to: point(0.50, 0.635), control: point(0.57, 0.595))
            path.addQuadCurve(to: point(0.435, 0.565), control: point(0.43, 0.595))
        case .bandana:
            path.move(to: point(0.25, 0.73))
            path.addLine(to: point(0.75, 0.73))
            path.addQuadCurve(to: point(0.50, 0.985), control: point(0.63, 0.89))
            path.addQuadCurve(to: point(0.25, 0.73), control: point(0.38, 0.89))
        }
        path.closeSubpath()
        return path
    }
}

extension DogBandanaColor {
    var avatarColor: Color {
        switch self {
        case .none: return .clear
        case .red: return Color(red: 0.88, green: 0.22, blue: 0.25)
        case .green: return Color(red: 0.28, green: 0.61, blue: 0.29)
        case .yellow: return Color(red: 0.98, green: 0.76, blue: 0.19)
        }
    }
}
