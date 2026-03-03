#!/usr/bin/env swift

import Cocoa
import Foundation

// Usage: ./iconoverlay.swift <input.icns> <output.icns> <text> <baseFontSize>

guard CommandLine.arguments.count == 5 else {
    print("Usage: iconoverlay.swift <input.icns> <output.icns> <text> <baseFontSize>")
    exit(1)
}

let inputIconPath = CommandLine.arguments[1]
let outputIconPath = CommandLine.arguments[2]
let text = CommandLine.arguments[3]
let baseFontSize = CGFloat(Double(CommandLine.arguments[4]) ?? 72.0)

let fileManager = FileManager.default
let tempDir = NSTemporaryDirectory()
let iconsetPath = tempDir + "temp.iconset"

// Clean up any existing temp iconset
try? fileManager.removeItem(atPath: iconsetPath)

// Extract iconset from .icns
print("Extracting iconset from \(inputIconPath)...")
let extractTask = Process()
extractTask.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
extractTask.arguments = ["-c", "iconset", inputIconPath, "-o", iconsetPath]
try? extractTask.run()
extractTask.waitUntilExit()

guard extractTask.terminationStatus == 0 else {
    print("Failed to extract iconset")
    exit(1)
}

// Function to add text overlay with wrapping at the top
func addText(to imagePath: String, text: String, fontSize: CGFloat, topPadding: CGFloat) -> Bool {
    guard let image = NSImage(contentsOfFile: imagePath) else {
        print("  ✗ Failed to load image: \(imagePath)")
        return false
    }
    
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
        print("  ✗ Failed to get bitmap: \(imagePath)")
        return false
    }
    
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    let size = NSSize(width: width, height: height)
    
    // Create a new image with explicit size
    let newImage = NSImage(size: size)
    
    newImage.lockFocus()
    
    // Draw original image
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy,
               fraction: 1.0)
    
    // Prepare text attributes
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byWordWrapping
    
    // Calculate text layout area (leave padding on sides and top)
    let sidePadding = size.width * 0.1
    let textWidth = size.width - (sidePadding * 2)
    let maxTextHeight = size.height * 0.5 // Use up to half the icon height
    
    // Calculate actual text bounds for outline
    let tempAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: paragraphStyle
    ]
    let textBounds = text.boundingRect(
        with: NSSize(width: textWidth, height: maxTextHeight),
        options: [.usesLineFragmentOrigin],
        attributes: tempAttributes
    )
    
    // Position text at top with padding
    let textY = size.height - textBounds.height - topPadding
    let finalTextRect = NSRect(
        x: sidePadding,
        y: textY,
        width: textWidth,
        height: textBounds.height
    )
    
    // Draw black outline by drawing the text multiple times with offset
    let outlineWidth = max(1, Int(fontSize / 24))
    let blackAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.black,
        .paragraphStyle: paragraphStyle
    ]
    
    for dx in -outlineWidth...outlineWidth {
        for dy in -outlineWidth...outlineWidth {
            if dx == 0 && dy == 0 { continue }
            let offsetRect = NSRect(
                x: finalTextRect.origin.x + CGFloat(dx),
                y: finalTextRect.origin.y + CGFloat(dy),
                width: finalTextRect.width,
                height: finalTextRect.height
            )
            text.draw(with: offsetRect, options: [.usesLineFragmentOrigin], attributes: blackAttributes)
        }
    }
    
    // Draw red text on top
    let redAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.red,
        .paragraphStyle: paragraphStyle
    ]
    text.draw(with: finalTextRect, options: [.usesLineFragmentOrigin], attributes: redAttributes)
    
    newImage.unlockFocus()
    
    // Create final bitmap with correct dimensions
    guard let finalRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32) else {
        print("  ✗ Failed to create final bitmap: \(imagePath)")
        return false
    }
    
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: finalRep)
    NSGraphicsContext.current = context
    
    newImage.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    
    NSGraphicsContext.restoreGraphicsState()
    
    // Save as PNG
    guard let pngData = finalRep.representation(using: .png, properties: [:]) else {
        print("  ✗ Failed to create PNG data: \(imagePath)")
        return false
    }
    
    do {
        try pngData.write(to: URL(fileURLWithPath: imagePath))
        return true
    } catch {
        print("  ✗ Failed to write file: \(imagePath) - \(error)")
        return false
    }
}

// Process all PNG files in iconset
guard let files = try? fileManager.contentsOfDirectory(atPath: iconsetPath) else {
    print("Failed to read iconset directory")
    exit(1)
}

let pngFiles = files.filter { $0.hasSuffix(".png") }.sorted()
print("\nFound \(pngFiles.count) PNG files to process:")
for file in pngFiles {
    print("  - \(file)")
}
print("")

var successCount = 0

for file in pngFiles {
    let path = iconsetPath + "/" + file
    
    guard let image = NSImage(contentsOfFile: path),
          let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
        print("✗ \(file): Could not load")
        continue
    }
    
    let width = CGFloat(bitmap.pixelsWide)
    
    // Scale font size proportionally but keep it reasonable
    let scale = width / 512.0
    let fontSize = baseFontSize * scale
    let topPadding = width * 0.05 // 5% padding from top
    
    print("Processing \(file) (\(Int(width))px) - font: \(Int(fontSize)), padding: \(Int(topPadding))")
    
    if addText(to: path, text: text, fontSize: fontSize, topPadding: topPadding) {
        print("  ✓ Success")
        successCount += 1
    }
}

print("\nProcessed \(successCount) of \(pngFiles.count) files successfully")

// Convert iconset back to .icns
print("\nConverting iconset to .icns...")
let convertTask = Process()
convertTask.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convertTask.arguments = ["-c", "icns", iconsetPath, "-o", outputIconPath]
try? convertTask.run()
convertTask.waitUntilExit()

guard convertTask.terminationStatus == 0 else {
    print("Failed to convert iconset to .icns")
    exit(1)
}

// Clean up temp iconset
try? fileManager.removeItem(atPath: iconsetPath)

print("\n✓ Icon created successfully: \(outputIconPath)")