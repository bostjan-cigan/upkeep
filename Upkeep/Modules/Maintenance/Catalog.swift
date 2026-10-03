import SwiftUI

/// Keys match the SVG files in `Icons/`. Keys are stored in iCloud, so never rename one.
enum IconKey: String, CaseIterable, Identifiable {
    // Kitchen
    case dishwasher, fridge, oven, stove, hood, microwave, coffee, kettle, jug, trash
    // Laundry & bathroom
    case washer, dryer, iron, shower, toilet, faucet
    // Living & bedroom
    case window, door, floor, rug, sofa, curtains, bed, lamp, tv, router
    // Climate & cleaning
    case ac, radiator, waterheater, purifier, humidifier, fan
    /// Robot vacuum.
    case vacuum
    case stickvac
    /// Feather duster, for dusting a room.
    case duster
    // Safety & other
    case smoke, extinguisher, firstaid, plant, balcony, paw, generic
    var id: String { rawValue }
}

enum TileColor: String, CaseIterable, Identifiable {
    case blue, teal, green, yellow, orange, red, pink, purple, indigo, brown, gray
    var id: String { rawValue }

    var base: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .indigo: .indigo
        case .brown: .brown
        case .gray: .gray
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [base.mix(with: .white, by: 0.25), base], startPoint: .top, endPoint: .bottom)
    }

    /// What to draw on top of `base`. White washes out on the light half of the palette, and the
    /// gradient lightens the top by another quarter, so those carry a dark mark instead.
    var onBase: Color {
        switch self {
        case .yellow, .teal, .green, .orange, .gray: .black.opacity(0.8)
        case .blue, .red, .pink, .purple, .indigo, .brown: .white
        }
    }
}

struct TaskSuggestion: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let value: Int
    let unit: IntervalUnit

    init(_ title: String, _ value: Int, _ unit: IntervalUnit) {
        self.title = title
        self.value = value
        self.unit = unit
    }
}

enum TemplateCategory: String, CaseIterable, Identifiable {
    case kitchen = "Kitchen"
    case laundry = "Laundry"
    case bathroom = "Bathroom"
    case living = "Living & Bedroom"
    case climate = "Heating, Cooling & Air"
    case cleaning = "Cleaning"
    case safety = "Safety"
    case other = "Other"
    var id: String { rawValue }
}

struct ItemTemplate: Identifiable {
    let id: String
    let name: String
    let icon: IconKey
    let color: TileColor
    let category: TemplateCategory
    var room: String = ""
    let suggestions: [TaskSuggestion]

    static func inCategory(_ c: TemplateCategory) -> [ItemTemplate] { all.filter { $0.category == c } }

    static let all: [ItemTemplate] = [
        // MARK: Kitchen
        .init(id: "dishwasher", name: "Dishwasher", icon: .dishwasher, color: .blue, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Clean the filter", 1, .month),
            .init("Run a cleaning cycle", 1, .month),
            .init("Refill salt & rinse aid", 1, .month),
            .init("Wipe the door seal", 1, .month),
            .init("Clean the spray arms", 3, .month),
        ]),
        .init(id: "fridge", name: "Fridge", icon: .fridge, color: .indigo, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Toss expired food", 1, .week),
            .init("Clean shelves & drawers", 1, .month),
            .init("Clean the door seals", 3, .month),
            .init("Replace the odor absorber", 3, .month),
            .init("Vacuum the condenser coils", 6, .month),
        ]),
        .init(id: "freezer", name: "Freezer", icon: .fridge, color: .teal, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Sort & use up old food", 3, .month),
            .init("Clean the door seals", 3, .month),
            .init("Defrost", 6, .month),
        ]),
        .init(id: "oven", name: "Oven", icon: .oven, color: .orange, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Clean the door glass", 1, .month),
            .init("Clean the interior", 3, .month),
            .init("Clean the racks & trays", 3, .month),
        ]),
        .init(id: "stove", name: "Stovetop", icon: .stove, color: .red, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Degrease the stovetop", 1, .week),
            .init("Deep-clean burners or glass", 1, .month),
            .init("Clean the knobs", 1, .month),
        ]),
        .init(id: "hood", name: "Range Hood", icon: .hood, color: .gray, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Clean the grease filters", 1, .month),
            .init("Wipe the outside", 1, .month),
            .init("Replace the carbon filter", 6, .month),
        ]),
        .init(id: "microwave", name: "Microwave", icon: .microwave, color: .teal, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Steam-clean the inside", 2, .week),
            .init("Wash the turntable", 2, .week),
        ]),
        .init(id: "coffee", name: "Coffee Machine", icon: .coffee, color: .brown, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Rinse the brew group", 1, .week),
            .init("Clean the milk frother", 1, .week),
            .init("Empty & wash the drip tray", 1, .week),
            .init("Descale", 2, .month),
            .init("Replace the water filter", 2, .month),
        ]),
        .init(id: "kettle", name: "Kettle", icon: .kettle, color: .green, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Descale", 1, .month),
            .init("Rinse the limescale filter", 1, .month),
        ]),
        .init(id: "jug", name: "Water Filter", icon: .jug, color: .blue, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Replace the filter cartridge", 1, .month),
            .init("Wash the jug", 2, .week),
        ]),
        .init(id: "kitchensink", name: "Kitchen Sink", icon: .faucet, color: .purple, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Replace the sponge", 2, .week),
            .init("Freshen the drain", 2, .week),
            .init("Descale the faucet", 1, .month),
            .init("Clean the aerator", 3, .month),
        ]),
        .init(id: "trash", name: "Trash & Recycling", icon: .trash, color: .green, category: .kitchen, room: "Kitchen", suggestions: [
            .init("Take out the recycling", 1, .week),
            .init("Wash the bins", 1, .month),
        ]),

        // MARK: Laundry
        .init(id: "washer", name: "Washing Machine", icon: .washer, color: .teal, category: .laundry, room: "Laundry", suggestions: [
            .init("Wipe the door seal", 2, .week),
            .init("Clean the drum (hot empty cycle)", 1, .month),
            .init("Clean the detergent drawer", 1, .month),
            .init("Clean the drain filter", 3, .month),
        ]),
        .init(id: "dryer", name: "Tumble Dryer", icon: .dryer, color: .indigo, category: .laundry, room: "Laundry", suggestions: [
            .init("Clean the lint filter", 1, .week),
            .init("Empty the water tank", 1, .week),
            .init("Rinse the condenser / heat pump filter", 1, .month),
        ]),
        .init(id: "iron", name: "Iron", icon: .iron, color: .pink, category: .laundry, room: "Laundry", suggestions: [
            .init("Clean the soleplate", 1, .month),
            .init("Descale", 3, .month),
        ]),

        // MARK: Bathroom
        .init(id: "shower", name: "Shower & Bath", icon: .shower, color: .teal, category: .bathroom, room: "Bathroom", suggestions: [
            .init("Scrub shower & tub", 1, .week),
            .init("Clean the drain", 1, .month),
            .init("Wash the shower curtain / squeegee glass", 1, .month),
            .init("Descale the shower head", 3, .month),
            .init("Scrub the grout", 3, .month),
            .init("Check the silicone seals", 1, .year),
        ]),
        .init(id: "toilet", name: "Toilet", icon: .toilet, color: .blue, category: .bathroom, room: "Bathroom", suggestions: [
            .init("Clean the toilet", 1, .week),
            .init("Descale the bowl", 1, .month),
            .init("Clean around the seat hinges", 1, .month),
            .init("Check for leaks & running flush", 6, .month),
        ]),
        .init(id: "bathsink", name: "Bathroom Sink", icon: .faucet, color: .purple, category: .bathroom, room: "Bathroom", suggestions: [
            .init("Descale the faucet", 1, .month),
            .init("Clear the drain", 1, .month),
            .init("Clean the aerator", 3, .month),
        ]),
        .init(id: "extractor", name: "Extractor Fan", icon: .fan, color: .gray, category: .bathroom, room: "Bathroom", suggestions: [
            .init("Clean the fan grille", 3, .month),
        ]),

        // MARK: Living & bedroom
        .init(id: "window", name: "Windows", icon: .window, color: .blue, category: .living, suggestions: [
            .init("Clean the glass", 3, .month),
            .init("Clean frames, sills & tracks", 6, .month),
            .init("Lubricate hinges & handles", 1, .year),
            .init("Check the seals", 1, .year),
        ]),
        .init(id: "door", name: "Doors & Handles", icon: .door, color: .green, category: .living, suggestions: [
            .init("Disinfect door handles & light switches", 1, .week),
            .init("Tighten handle screws", 6, .month),
            .init("Lubricate hinges & locks", 1, .year),
        ]),
        .init(id: "floor", name: "Floors", icon: .floor, color: .orange, category: .living, suggestions: [
            .init("Vacuum", 1, .week),
            .init("Mop", 2, .week),
            .init("Clean the baseboards", 3, .month),
            .init("Oil or polish wood floors", 1, .year),
        ]),
        .init(id: "rug", name: "Rugs & Carpets", icon: .rug, color: .red, category: .living, suggestions: [
            .init("Vacuum both sides", 1, .month),
            .init("Rotate", 6, .month),
            .init("Deep clean", 1, .year),
        ]),
        .init(id: "sofa", name: "Sofa", icon: .sofa, color: .brown, category: .living, room: "Living Room", suggestions: [
            .init("Vacuum the cushions", 1, .month),
            .init("Flip & fluff cushions", 1, .month),
            .init("Wash the covers", 6, .month),
        ]),
        .init(id: "curtains", name: "Curtains & Blinds", icon: .curtains, color: .purple, category: .living, suggestions: [
            .init("Dust the blinds", 1, .month),
            .init("Wash the curtains", 6, .month),
        ]),
        .init(id: "bed", name: "Bed & Mattress", icon: .bed, color: .orange, category: .living, room: "Bedroom", suggestions: [
            .init("Change the bed sheets", 1, .week),
            .init("Rotate the mattress", 3, .month),
            .init("Wash pillows & duvet", 6, .month),
            .init("Vacuum the mattress", 6, .month),
        ]),
        .init(id: "lamp", name: "Lights & Lamps", icon: .lamp, color: .yellow, category: .living, suggestions: [
            .init("Dust lamps & fixtures", 3, .month),
            .init("Check for dead bulbs", 6, .month),
        ]),
        .init(id: "tv", name: "TV & Electronics", icon: .tv, color: .indigo, category: .living, suggestions: [
            .init("Dust screens & vents", 1, .month),
            .init("Disinfect remotes & keyboards", 1, .month),
        ]),
        .init(id: "router", name: "Wi-Fi Router", icon: .router, color: .green, category: .living, suggestions: [
            .init("Restart", 1, .month),
            .init("Check for firmware updates", 6, .month),
        ]),

        // MARK: Heating, cooling & air
        .init(id: "ac", name: "Air Conditioner", icon: .ac, color: .blue, category: .climate, suggestions: [
            .init("Clean the filters", 1, .month),
            .init("Professional service", 1, .year),
        ]),
        .init(id: "radiator", name: "Heating", icon: .radiator, color: .red, category: .climate, suggestions: [
            .init("Dust the radiators", 1, .month),
            .init("Bleed the radiators", 1, .year),
            .init("Boiler service", 1, .year),
        ]),
        .init(id: "waterheater", name: "Water Heater", icon: .waterheater, color: .orange, category: .climate, suggestions: [
            .init("Check the pressure & for leaks", 3, .month),
            .init("Flush & descale", 1, .year),
            .init("Professional service", 1, .year),
        ]),
        .init(id: "purifier", name: "Air Purifier", icon: .purifier, color: .teal, category: .climate, suggestions: [
            .init("Vacuum the pre-filter", 1, .month),
            .init("Replace the HEPA filter", 6, .month),
        ]),
        .init(id: "humidifier", name: "Humidifier / Dehumidifier", icon: .humidifier, color: .blue, category: .climate, suggestions: [
            .init("Empty & rinse the tank", 1, .week),
            .init("Descale", 1, .month),
            .init("Clean or replace the filter", 3, .month),
        ]),
        .init(id: "fan", name: "Fan", icon: .fan, color: .teal, category: .climate, suggestions: [
            .init("Dust the blades & grille", 1, .month),
        ]),

        // MARK: Cleaning
        .init(id: "robotvacuum", name: "Robot Vacuum", icon: .vacuum, color: .purple, category: .cleaning, suggestions: [
            .init("Empty the dust bin", 3, .day),
            .init("Wash the mop pad", 1, .week),
            .init("Empty & rinse the dirty water tank", 1, .week),
            .init("Refill & rinse the clean water tank", 1, .week),
            .init("Untangle the main & side brushes", 2, .week),
            .init("Tap out & rinse the filter", 2, .week),
            .init("Wipe sensors, wheels & charging contacts", 1, .month),
            .init("Replace the dock's dust bag", 2, .month),
            .init("Replace the filter", 3, .month),
            .init("Replace the side brush", 6, .month),
            .init("Replace the main brush", 1, .year),
        ]),
        .init(id: "stickvac", name: "Vacuum Cleaner", icon: .stickvac, color: .indigo, category: .cleaning, suggestions: [
            .init("Empty & rinse the dust bin", 2, .week),
            .init("Untangle the brush roll", 1, .month),
            .init("Wash or replace the filter", 3, .month),
        ]),
        .init(id: "dusting", name: "Dusting", icon: .duster, color: .pink, category: .cleaning, suggestions: [
            .init("Dust surfaces", 1, .week),
            .init("Dust shelves, frames & light fixtures", 1, .month),
        ]),

        // MARK: Safety
        .init(id: "smoke", name: "Smoke Detector", icon: .smoke, color: .red, category: .safety, suggestions: [
            .init("Test the alarm", 1, .month),
            .init("Replace the battery", 1, .year),
        ]),
        .init(id: "co", name: "Carbon Monoxide Detector", icon: .smoke, color: .orange, category: .safety, suggestions: [
            .init("Test the alarm", 1, .month),
            .init("Replace the battery", 1, .year),
        ]),
        .init(id: "extinguisher", name: "Fire Extinguisher", icon: .extinguisher, color: .red, category: .safety, suggestions: [
            .init("Check the pressure gauge", 6, .month),
            .init("Professional inspection", 1, .year),
        ]),
        .init(id: "firstaid", name: "First Aid Kit", icon: .firstaid, color: .green, category: .safety, suggestions: [
            .init("Check expiry dates", 6, .month),
            .init("Restock supplies", 1, .year),
        ]),

        // MARK: Other
        .init(id: "plant", name: "Plants", icon: .plant, color: .green, category: .other, suggestions: [
            .init("Water", 1, .week),
            .init("Dust the leaves", 1, .month),
            .init("Fertilize", 1, .month),
            .init("Repot", 1, .year),
        ]),
        .init(id: "balcony", name: "Balcony", icon: .balcony, color: .teal, category: .other, room: "Balcony", suggestions: [
            .init("Sweep", 2, .week),
            .init("Clear the drain", 3, .month),
            .init("Wash the railing & furniture", 6, .month),
        ]),
        .init(id: "pet", name: "Pet", icon: .paw, color: .brown, category: .other, suggestions: [
            .init("Wash food & water bowls", 1, .day),
            .init("Clean the litter box", 1, .day),
            .init("Wash the pet bed", 1, .month),
            .init("Flea & tick treatment", 1, .month),
        ]),
        .init(id: "custom", name: "Something Else", icon: .generic, color: .gray, category: .other, suggestions: []),
    ]
}
