#!/usr/bin/env swift
// Turns a screen recording into a GIF for the docs, with nothing to install:
// AVFoundation reads the movie and ImageIO writes the GIF.
//
//   swift scripts/mp4-to-gif.swift <in.mp4> <out.gif> [--width 300] [--fps 8]
//                                  [--from 0] [--to <end>] [--speed 1] [--hold 0]
//
// --from/--to trim the recording (seconds), --speed above 1 plays it faster,
// and --hold keeps the last frame up for that many seconds, so a result that
// appears just before the recording stops can still be read.
// See CONTRIBUTING.md for how the recordings themselves are made.

import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
  fail("usage: mp4-to-gif.swift <in.mp4> <out.gif> [--width 300] [--fps 8] [--from s] [--to s] [--speed x] [--hold s]")
}
let input = URL(fileURLWithPath: args.removeFirst())
let output = URL(fileURLWithPath: args.removeFirst())

var options: [String: Double] = ["width": 300, "fps": 8, "from": 0, "speed": 1, "hold": 0]
while args.count >= 2, args[0].hasPrefix("--") {
  let key = String(args.removeFirst().dropFirst(2))
  guard let value = Double(args.removeFirst()) else { fail("--\(key) needs a number") }
  options[key] = value
}

let asset = AVURLAsset(url: input)
let duration = CMTimeGetSeconds(asset.duration)
guard duration > 0 else { fail("could not read \(input.path)") }

let from = options["from"]!
let to = min(options["to"] ?? duration, duration)
let fps = options["fps"]!
let speed = options["speed"]!

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: options["width"]!, height: 0)
// Exact frames: the default tolerance hands back whichever key frame is near,
// which makes a screen recording stutter.
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

// Source time advances by `speed` seconds per second of GIF.
let step = speed / fps
let times = stride(from: from, to: to, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }

guard let destination = CGImageDestinationCreateWithURL(
  output as CFURL, UTType.gif.identifier as CFString, times.count + 1, nil
) else { fail("could not write \(output.path)") }

CGImageDestinationSetProperties(destination, [
  kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)

let frameProperties = [
  kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps],
] as CFDictionary

var last: CGImage?
for time in times {
  guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
  CGImageDestinationAddImage(destination, frame, frameProperties)
  last = frame
}
if let last, options["hold"]! > 0 {
  CGImageDestinationAddImage(destination, last, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: options["hold"]!],
  ] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fail("could not finish \(output.path)") }

let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("\(output.lastPathComponent): \(times.count) frames, \(bytes / 1024) KB")
