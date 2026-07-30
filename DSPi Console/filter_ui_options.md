# Filter Type Selector UI Options

Here are several modern approaches to styling the filter type selector in SwiftUI for macOS.

## 1. Minimalist Text (Current)
**Description:** Displays only the active filter name. No borders or backgrounds until clicked. Very clean, reduces visual noise in dense lists.
**Code:**
```swift
Menu {
    // options
} label: {
    Text(params.type.name)
        .font(.system(.body))
}
.menuStyle(.borderlessButton)
```

## 2. Ghost Button (Hover Reveal)
**Description:** Text appears plain by default, but a subtle rounded rectangle background appears when the mouse hovers over it. Provides affordance without clutter.
**Code:**
```swift
@State private var isHovering = false
// ...
Menu { ... } label: {
    Text(params.type.name)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovering ? Color.secondary.opacity(0.1) : Color.clear)
        .cornerRadius(4)
}
.menuStyle(.borderlessButton)
.onHover { isHovering = $0 }
```

## 3. Modern Pill
**Description:** A capsule-shaped button with a light border and a small chevron icon. Resembles modern web/mobile dropdowns.
**Code:**
```swift
Menu { ... } label: {
    HStack(spacing: 4) {
        Text(params.type.name).font(.subheadline)
        Image(systemName: "chevron.down").font(.caption2)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().stroke(Color.secondary.opacity(0.3)))
}
.menuStyle(.borderlessButton)
```

## 4. Icon-Based
**Description:** Replaces text with a symbol representing the filter shape (High Pass, Peaking, etc.) if available, or adds an icon next to the text.
**Code:**
```swift
Menu { ... } label: {
    Label(params.type.name, systemImage: "waveform.path") // Dynamic icon per type
        .labelStyle(.titleAndIcon)
}
```

## 5. Inline Segmented (Mini)
**Description:** If only a few types are commonly used, a tiny segmented control directly in the row.
**Pros:** One-click access.
**Cons:** Takes up too much horizontal space for many options.

## 6. Glassmorphism
**Description:** Semi-transparent background with a blur effect. Matches the "console" aesthetic.
**Code:**
```swift
.background(.ultraThinMaterial)
.cornerRadius(6)
```
