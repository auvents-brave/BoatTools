// MARK: - TalkerId

/// NMEA 0183 talker identifier (the two-character prefix after `$`).
public enum TalkerId: String, Sendable, Equatable {
	case AB, AD, AG, AI, AN, AP, AR, AT, AX, AY
	case BD, BN
	case CA, CC, CD, CR, CS, CT, CV, CX
	case DE, DF, DM, DP, DU
	case EC, EI, EP, ER
	case GA, GB, GI, GL, GN, GP, GQ, GR, GW
	case HC, HE, HF, HN, HO, HP, HR
	case IA, IC, II, IN, IS
	case LC, LP, MX
	case NI, NL
	case OM, OS
	case P
	case QZ
	case RA, RB, RC, RD, RE, RI, RM
	case SA, SD, SG, SH, SI, SL, SM, SN, SS, ST, SX
	case TC, TI
	case U0, U1, U2, U3, U4, U5, U6, U7, U8, U9
	case UP
	case VA, VD, VM, VR, VS, VT, VW
	case WA, WI, WL
	case XR, XW
	case YC, YD, YX
	case ZA, ZC, ZG, ZH, ZW

	/// Human-readable description.
	public var label: String {
		switch self {
		case .AB: return "Independent AIS Base Station"
		case .AD: return "AIS Display Unit"
		case .AG: return "Autopilot General"
		case .AI: return "Mobile Class A or B AIS Station"
		case .AN: return "AIS Aids to Navigation Station"
		case .AP: return "Autopilot"
		case .AR: return "AIS Receiving Station"
		case .AT: return "AIS Transmitting Station"
		case .AX: return "AIS Simplex Repeater Station"
		case .AY: return "AIS Base Station"
		case .BD: return "BeiDou (China)"
		case .BN: return "Bridge Navigational Watch Alarm System"
		case .CA: return "Central Alert Management"
		case .CC: return "Computer — Programmed Calculator"
		case .CD: return "DSC (Digital Selective Calling)"
		case .CR: return "Clock — Receiver General"
		case .CS: return "Communications — Satellite"
		case .CT: return "Communications — Radio-Telephone (MF/HF)"
		case .CV: return "Communications — Radio-Telephone (VHF)"
		case .CX: return "Communications — Scanning Receiver"
		case .DE: return "DECCA Navigation"
		case .DF: return "Direction Finder"
		case .DM: return "Velocity Sensor — Speed Log — Water Magnetic"
		case .DP: return "Dynamic Position"
		case .DU: return "Duplex Repeater Station"
		case .EC: return "Electronic Chart System (ECS)"
		case .EI: return "Electronic Chart & Display Information System (ECDIS)"
		case .EP: return "Emergency Position Indicating Beacon (EPIRB)"
		case .ER: return "Engine Room Monitoring Systems"
		case .GA: return "Galileo Receiver"
		case .GB: return "BeiDou (China) — alternate"
		case .GI: return "NavIC (India)"
		case .GL: return "GLONASS Receiver"
		case .GN: return "Global Navigation Satellite System (GNSS)"
		case .GP: return "GPS Receiver"
		case .GQ: return "QZSS"
		case .GR: return "GLONASS — alternate"
		case .GW: return "GNSS Wide Area Augmentation System (WAAS)"
		case .HC: return "Compass — Heading Track Controller"
		case .HE: return "Gyro — Non-North Seeking"
		case .HF: return "Fluxgate Compass"
		case .HN: return "Gyro — North Seeking"
		case .HO: return "Gyro — Optical"
		case .HP: return "Heading Sensor — Passive"
		case .HR: return "Rate Gyro"
		case .IA: return "Integrated Automation"
		case .IC: return "Integrated Communications"
		case .II: return "Integrated Instrumentation"
		case .IN: return "Integrated Navigation"
		case .IS: return "Integrated Systems"
		case .LC: return "Loran C"
		case .LP: return "Long-Range Positioning System (LORAN)"
		case .MX: return "Multiplexer"
		case .NI: return "Navigation Computer Solution"
		case .NL: return "Navigation Light Controller"
		case .OM: return "OMEGA Navigation System"
		case .OS: return "Distress Alarm System"
		case .P: return "Proprietary"
		case .QZ: return "QZSS (Japan)"
		case .RA: return "RADAR and/or ARPA"
		case .RB: return "Record Book"
		case .RC: return "Propulsion Machinery Including Remote Control"
		case .RD: return "RADAR"
		case .RE: return "Receive — Electronics"
		case .RI: return "Rudder Angle Indicator"
		case .RM: return "Route Management"
		case .SA: return "Physical Shore AIS Station"
		case .SD: return "Depth Sounder"
		case .SG: return "Steering Gear / Steering Engine"
		case .SH: return "Steering Hand"
		case .SI: return "Steering System — Integral"
		case .SL: return "Speed Log"
		case .SM: return "Steering System — Magnetic"
		case .SN: return "Electronic Positioning System — Other/General"
		case .SS: return "Scanning Sounder"
		case .ST: return "Skytraq"
		case .SX: return "Proprietary — manufacturer TBD"
		case .TC: return "Track Control"
		case .TI: return "Turn Rate Indicator"
		case .U0, .U1, .U2, .U3, .U4, .U5, .U6, .U7, .U8, .U9: return "User Configured"
		case .UP: return "Microprocessor Controller"
		case .VA: return "VHF Data Exchange System (VDES) — ASM"
		case .VD: return "Velocity Sensor — Doppler Other/General"
		case .VM: return "Velocity Sensor — Speed Log — Water Magnetic"
		case .VR: return "Voyage Data Recorder"
		case .VS: return "VDES — Satellite"
		case .VT: return "VDES — Terrestrial"
		case .VW: return "Velocity Sensor — Speed Log — Water Mechanical"
		case .WA: return "Weather Instruments"
		case .WI: return "Weather Instruments"
		case .WL: return "Water Level"
		case .XR: return "Transducer — Temperature"
		case .XW: return "Transducer — Volume"
		case .YC: return "Transducer — Temperature (obsolete)"
		case .YD: return "Transducer — Displacement (obsolete)"
		case .YX: return "Transducer"
		case .ZA: return "Timekeeper — Atomic Clock"
		case .ZC: return "Timekeeper — Chronometer"
		case .ZG: return "Timekeeper — GPS"
		case .ZH: return "Timekeeper — LORAN"
		case .ZW: return "Timekeeper — Radio Update"
		}
	}
}

// MARK: - MessageId

/// NMEA 0183 sentence type (the three-character suffix after the talker ID).
public enum MessageId: String, Sendable, Equatable {
	case AAM, ABK, ACA, ACK, ACN, ACS, ADS, AFI, AGN, AIG
	case AIR, AIS, AKD, ALA, ALM, ALR, AMS, APB, ASD
	case BBM, BEC, BOD, BWC, BWR, BWW
	case CEK, COP, CUR
	case DBK, DBS, DBT, DCN, DCR, DDC, DOR, DPT, DRU, DSC, DSE, DSI, DSR, DTM, DZA
	case ECE, ECF, ECD, ECG, ECL, ECS, ECT, ECU
	case FSI
	case GBS, GGA, GLC, GLL, GMP, GNS, GRS, GSA, GST, GSV, GTD, GXA
	case HDG, HDM, HDT, HMR, HMS, HRM, HSC, HTC, HTD, HVD
	case ITS
	case LCD, LRF, LRI, LR1, LR2, LR3
	case MDA, MHU, MKD, MMB, MOB, MSK, MSS, MTW, MWD, MWV
	case NAK, NRM, NRX, NSR, NTL
	case OLN, ORA, OSD
	case POS, PRC
	case RLM, RMA, RMB, RMC, ROT, RPM, RSA, RSD, RTE
	case SFI, SM1, SM2, SM3, SM4, SMI, SMS, SSD, STN
	case TDS, TFI, TGA, TIF, TLL, TPC, TPR, TPT, TRF, TTM, TTN, TUT, TXT
	case UID, ULN
	case VBW, VDM, VDO, VDR, VER, VHW, VLW, VPW, VSD, VTG, VWR, VWT
	case WCV, WNC, WPL
	case XDR, XTE, XTR
	case ZDA, ZDL, ZFO, ZTG

	/// Human-readable description.
	public var label: String {
		switch self {
		case .AAM: return "Waypoint Arrival Alarm"
		case .ABK: return "AIS Addressed and Binary Broadcast Acknowledgement"
		case .ACA: return "AIS Channel Assignment Message"
		case .ACK: return "Acknowledge Alarm"
		case .ACN: return "Alert Command Refused"
		case .ACS: return "AIS Channel Management Info Source"
		case .ADS: return "Automatic Device Status"
		case .AFI: return "AIS Filter Information"
		case .AGN: return "Aggregated Alert"
		case .AIG: return "AIS Group Assignment"
		case .AIR: return "AIS Interrogation Request"
		case .AIS: return "AIS Information"
		case .AKD: return "Acknowledge Detail Alarm"
		case .ALA: return "Set Detail Alarm Condition"
		case .ALM: return "GPS Almanac Data"
		case .ALR: return "Set Alarm State"
		case .AMS: return "AIS Message Statistics"
		case .APB: return "Autopilot Sentence B"
		case .ASD: return "Autopilot System Data"
		case .BBM: return "AIS Broadcast Binary Message"
		case .BEC: return "Bearing and Distance to Waypoint — Dead Reckoning"
		case .BOD: return "Bearing — Origin to Destination"
		case .BWC: return "Bearing and Distance to Waypoint"
		case .BWR: return "Bearing and Distance to Waypoint — Rhumb Line"
		case .BWW: return "Bearing — Waypoint to Waypoint"
		case .CEK: return "Configure Encryption Key"
		case .COP: return "Configuring Operating Parameters"
		case .CUR: return "Water Current Layer"
		case .DBK: return "Depth Below Keel"
		case .DBS: return "Depth Below Surface"
		case .DBT: return "Depth Below Transducer"
		case .DCN: return "DECCA Position"
		case .DCR: return "DECCA Receiver Channels"
		case .DDC: return "Display Dimming Control"
		case .DOR: return "Door Status Detection"
		case .DPT: return "Depth"
		case .DRU: return "Dual Doppler Auxiliary Data"
		case .DSC: return "Digital Selective Calling Information"
		case .DSE: return "Expanded DSC"
		case .DSI: return "DSC Transponder Initialise"
		case .DSR: return "DSC Transponder Response"
		case .DTM: return "Datum Reference"
		case .DZA: return "Time and Distance to Variable Point"
		case .ECE: return "Electronic Chart Editor Commands"
		case .ECF: return "Electronic Chart Editor Format Commands"
		case .ECD: return "Electronic Chart Display Commands"
		case .ECG: return "Electronic Chart Display Commands"
		case .ECL: return "Electronic Chart Display Commands"
		case .ECS: return "Electronic Chart Display Commands"
		case .ECT: return "Electronic Chart Display Commands"
		case .ECU: return "Electronic Chart Display Commands"
		case .FSI: return "Frequency Set Information"
		case .GBS: return "GPS Satellite Fault Detection"
		case .GGA: return "Global Positioning System Fix Data"
		case .GLC: return "Geographic Position — Loran-C"
		case .GLL: return "Geographic Position — Latitude/Longitude"
		case .GMP: return "GNSS Map Projection Fix Data"
		case .GNS: return "Fix Data"
		case .GRS: return "GPS Range Residuals"
		case .GSA: return "GPS DOP and Active Satellites"
		case .GST: return "GPS Pseudorange Noise Statistics"
		case .GSV: return "Satellites in View"
		case .GTD: return "Geographic Location in Time Differences"
		case .GXA: return "TRANSIT Position"
		case .HDG: return "Heading — Deviation and Variation"
		case .HDM: return "Heading — Magnetic"
		case .HDT: return "Heading — True"
		case .HMR: return "Heading Monitor Receive"
		case .HMS: return "Heading Monitor Set"
		case .HRM: return "Heel Angle, Roll Period and Roll Amplitude"
		case .HSC: return "Heading Steering Command"
		case .HTC: return "Heading Track Control Command"
		case .HTD: return "Heading Track Control Data"
		case .HVD: return "Magnetic Variation"
		case .ITS: return "Trawl Door Spread 2 Distance"
		case .LCD: return "Loran-C Signal Data"
		case .LRF: return "AIS Long Range Function"
		case .LRI: return "AIS Long Range Interrogation"
		case .LR1: return "AIS Long Range Reply Sentence 1"
		case .LR2: return "AIS Long Range Reply Sentence 2"
		case .LR3: return "AIS Long Range Reply Sentence 3"
		case .MDA: return "Meteorological Composite"
		case .MHU: return "Humidity"
		case .MKD: return "Magnetic Compass Keyboard Data"
		case .MMB: return "Barometer"
		case .MOB: return "Man Over Board Notification"
		case .MSK: return "Control for a Beacon Receiver"
		case .MSS: return "Beacon Receiver Status"
		case .MTW: return "Water Temperature"
		case .MWD: return "Wind Direction and Speed"
		case .MWV: return "Wind Speed and Angle"
		case .NAK: return "Negative Acknowledgement"
		case .NRM: return "NAVTEX Receiver Mask"
		case .NRX: return "NAVTEX Received Message"
		case .NSR: return "Navigation Status Report"
		case .NTL: return "Navigate to Layer"
		case .OLN: return "Omega Lane Numbers"
		case .ORA: return "Owner and Registration"
		case .OSD: return "Own Ship Data"
		case .POS: return "Device Position and Ship Dimensions"
		case .PRC: return "Propulsion Remote Control Status"
		case .RLM: return "Return Link Message"
		case .RMA: return "Recommended Minimum Navigation — Loran-C Data"
		case .RMB: return "Recommended Minimum Navigation Information"
		case .RMC: return "Recommended Minimum Navigation Data"
		case .ROT: return "Rate of Turn"
		case .RPM: return "Revolutions"
		case .RSA: return "Rudder Sensor Angle"
		case .RSD: return "RADAR System Data"
		case .RTE: return "Routes"
		case .SFI: return "Scanning Frequency Information"
		case .SM1: return "Sentence Muting — All Sentences"
		case .SM2: return "Sentence Muting — By Sentence Formatter"
		case .SM3: return "Sentence Muting — By Data and Device"
		case .SM4: return "Sentence Muting — By Data"
		case .SMI: return "Sentence Muting — Individual Sentences"
		case .SMS: return "Sentence Muting — Status"
		case .SSD: return "AIS Ship Static Data"
		case .STN: return "Multiple Data ID"
		case .TDS: return "Trawl Door Spread Distance"
		case .TFI: return "Trawl Filling Indicator"
		case .TGA: return "Track to Geographic Area"
		case .TIF: return "Trawl Instrument Freeze"
		case .TLL: return "Target Latitude and Longitude"
		case .TPC: return "Trawl Position Cartesian Coordinates"
		case .TPR: return "Trawl Position Relative Vessel"
		case .TPT: return "Trawl Position True"
		case .TRF: return "Transit Fix Data"
		case .TTM: return "Tracked Target Message"
		case .TTN: return "Tracked Target Name"
		case .TUT: return "Transmission of Multi-language Text"
		case .TXT: return "Text Transmission"
		case .UID: return "User Identification Code Transmission"
		case .ULN: return "Ultra High Speed Link"
		case .VBW: return "Dual Ground/Water Speed"
		case .VDM: return "AIS VHF Data-Link Message"
		case .VDO: return "AIS VHF Data-Link Own-Vessel Report"
		case .VDR: return "Set and Drift"
		case .VER: return "Version"
		case .VHW: return "Water Speed and Heading"
		case .VLW: return "Distance Traveled Through the Water"
		case .VPW: return "Speed — Measured Parallel to Wind"
		case .VSD: return "AIS Voyage Static Data"
		case .VTG: return "Track Made Good and Ground Speed"
		case .VWR: return "Relative Wind Speed and Angle"
		case .VWT: return "True Wind Speed and Angle"
		case .WCV: return "Waypoint Closure Velocity"
		case .WNC: return "Distance — Waypoint to Waypoint"
		case .WPL: return "Waypoint Location"
		case .XDR: return "Transducer Measurements"
		case .XTE: return "Cross-Track Error — Measured"
		case .XTR: return "Cross-Track Error — Dead Reckoning"
		case .ZDA: return "Time and Date"
		case .ZDL: return "Time and Distance to Variable Point"
		case .ZFO: return "UTC and Time from Origin Waypoint"
		case .ZTG: return "UTC and Time to Destination Waypoint"
		}
	}
}

// MARK: - AIS enums

/// AIS navigational status (field in message types 1/2/3).
public enum NavigationStatus: Int, Sendable, Equatable {
	case underWayUsingEngine = 0
	case atAnchor = 1
	case notUnderCommand = 2
	case restrictedManoeuvrability = 3
	case constrainedByDraught = 4
	case moored = 5
	case aground = 6
	case engagedInFishing = 7
	case underWaySailing = 8
	case reservedHSC = 9
	case reservedWIG = 10
	case powerDrivenVesselTowing = 11
	case powerDrivenVesselPushing = 12
	case reserved13 = 13
	case aisSearchAndRescue = 14
	case undefined = 15

	/// A human-readable label suitable for display.
	public var label: String {
		switch self {
		case .underWayUsingEngine: return String(localized: "Under Way Using Engine", bundle: .module)
		case .atAnchor: return String(localized: "At Anchor", bundle: .module)
		case .notUnderCommand: return String(localized: "Not Under Command", bundle: .module)
		case .restrictedManoeuvrability: return String(localized: "Restricted Manoeuvrability", bundle: .module)
		case .constrainedByDraught: return String(localized: "Constrained By Draught", bundle: .module)
		case .moored: return String(localized: "Moored", bundle: .module)
		case .aground: return String(localized: "Aground", bundle: .module)
		case .engagedInFishing: return String(localized: "Engaged in Fishing", bundle: .module)
		case .underWaySailing: return String(localized: "Under Way Sailing", bundle: .module)
		case .reservedHSC: return String(localized: "Reserved — HSC", bundle: .module)
		case .reservedWIG: return String(localized: "Reserved — WIG", bundle: .module)
		case .powerDrivenVesselTowing: return String(localized: "Power-Driven Vessel Towing Astern", bundle: .module)
		case .powerDrivenVesselPushing: return String(localized: "Power-Driven Vessel Pushing Ahead", bundle: .module)
		case .reserved13: return String(localized: "Reserved", bundle: .module)
		case .aisSearchAndRescue: return String(localized: "AIS-SART / MOB / EPIRB", bundle: .module)
		case .undefined: return String(localized: "Undefined", bundle: .module)
		}
	}
}

/// AIS vessel/ship type.
public enum ShipType: Int, Sendable, Equatable {
	case notAvailable = 0
	case wingInGround = 20
	case wingInGroundHazardousA = 21
	case wingInGroundHazardousB = 22
	case wingInGroundHazardousC = 23
	case wingInGroundHazardousD = 24
	case fishing = 30
	case towing = 31
	case towingLarge = 32
	case dredgingOrUnderwaterOps = 33
	case divingOps = 34
	case militaryOps = 35
	case sailing = 36
	case pleasureCraft = 37
	case highSpeedCraft = 40
	case highSpeedCraftHazardousA = 41
	case highSpeedCraftHazardousB = 42
	case highSpeedCraftHazardousC = 43
	case highSpeedCraftHazardousD = 44
	case pilotVessel = 50
	case searchAndRescue = 51
	case tug = 52
	case portTender = 53
	case antiPollution = 54
	case lawEnforcement = 55
	case localVessel56 = 56
	case localVessel57 = 57
	case medicalTransport = 58
	case noncombatantShip = 59
	case passenger = 60
	case passengerHazardousA = 61
	case passengerHazardousB = 62
	case passengerHazardousC = 63
	case passengerHazardousD = 64
	case passengerReserved65 = 65
	case passengerReserved66 = 66
	case passengerReserved67 = 67
	case passengerReserved68 = 68
	case passengerNoAdditional = 69
	case cargo = 70
	case cargoHazardousA = 71
	case cargoHazardousB = 72
	case cargoHazardousC = 73
	case cargoHazardousD = 74
	case cargoReserved75 = 75
	case cargoReserved76 = 76
	case cargoReserved77 = 77
	case cargoReserved78 = 78
	case cargoNoAdditional = 79
	case tanker = 80
	case tankerHazardousA = 81
	case tankerHazardousB = 82
	case tankerHazardousC = 83
	case tankerHazardousD = 84
	case tankerReserved85 = 85
	case tankerReserved86 = 86
	case tankerReserved87 = 87
	case tankerReserved88 = 88
	case tankerNoAdditional = 89
	case otherType = 90
	case otherHazardousA = 91
	case otherHazardousB = 92
	case otherHazardousC = 93
	case otherHazardousD = 94
	case otherReserved95 = 95
	case otherReserved96 = 96
	case otherReserved97 = 97
	case otherReserved98 = 98
	case otherNoAdditional = 99

	/// A human-readable label suitable for display.
	public var label: String {
		switch self {
		case .notAvailable: return String(localized: "Not Available", bundle: .module)
		case .wingInGround: return String(localized: "Wing In Ground", bundle: .module)
		case .wingInGroundHazardousA: return String(localized: "WIG — Hazardous Cat A", bundle: .module)
		case .wingInGroundHazardousB: return String(localized: "WIG — Hazardous Cat B", bundle: .module)
		case .wingInGroundHazardousC: return String(localized: "WIG — Hazardous Cat C", bundle: .module)
		case .wingInGroundHazardousD: return String(localized: "WIG — Hazardous Cat D", bundle: .module)
		case .fishing: return String(localized: "Fishing", bundle: .module)
		case .towing: return String(localized: "Towing", bundle: .module)
		case .towingLarge: return String(localized: "Towing — Large", bundle: .module)
		case .dredgingOrUnderwaterOps: return String(localized: "Dredging / Underwater Ops", bundle: .module)
		case .divingOps: return String(localized: "Diving Operations", bundle: .module)
		case .militaryOps: return String(localized: "Military Operations", bundle: .module)
		case .sailing: return String(localized: "Sailing", bundle: .module)
		case .pleasureCraft: return String(localized: "Pleasure Craft", bundle: .module)
		case .highSpeedCraft: return String(localized: "High Speed Craft", bundle: .module)
		case .highSpeedCraftHazardousA: return String(localized: "HSC — Hazardous Cat A", bundle: .module)
		case .highSpeedCraftHazardousB: return String(localized: "HSC — Hazardous Cat B", bundle: .module)
		case .highSpeedCraftHazardousC: return String(localized: "HSC — Hazardous Cat C", bundle: .module)
		case .highSpeedCraftHazardousD: return String(localized: "HSC — Hazardous Cat D", bundle: .module)
		case .pilotVessel: return String(localized: "Pilot Vessel", bundle: .module)
		case .searchAndRescue: return String(localized: "Search and Rescue", bundle: .module)
		case .tug: return String(localized: "Tug", bundle: .module)
		case .portTender: return String(localized: "Port Tender", bundle: .module)
		case .antiPollution: return String(localized: "Anti-Pollution Equipment", bundle: .module)
		case .lawEnforcement: return String(localized: "Law Enforcement", bundle: .module)
		case .localVessel56: return String(localized: "Local Vessel", bundle: .module)
		case .localVessel57: return String(localized: "Local Vessel", bundle: .module)
		case .medicalTransport: return String(localized: "Medical Transport", bundle: .module)
		case .noncombatantShip: return String(localized: "Noncombatant Ship", bundle: .module)
		case .passenger: return String(localized: "Passenger", bundle: .module)
		case .passengerHazardousA: return String(localized: "Passenger — Hazardous Cat A", bundle: .module)
		case .passengerHazardousB: return String(localized: "Passenger — Hazardous Cat B", bundle: .module)
		case .passengerHazardousC: return String(localized: "Passenger — Hazardous Cat C", bundle: .module)
		case .passengerHazardousD: return String(localized: "Passenger — Hazardous Cat D", bundle: .module)
		case .passengerReserved65,
			.passengerReserved66,
			.passengerReserved67,
			.passengerReserved68:
			return String(localized: "Passenger — Reserved", bundle: .module)
		case .passengerNoAdditional: return String(localized: "Passenger", bundle: .module)
		case .cargo: return String(localized: "Cargo", bundle: .module)
		case .cargoHazardousA: return String(localized: "Cargo — Hazardous Cat A", bundle: .module)
		case .cargoHazardousB: return String(localized: "Cargo — Hazardous Cat B", bundle: .module)
		case .cargoHazardousC: return String(localized: "Cargo — Hazardous Cat C", bundle: .module)
		case .cargoHazardousD: return String(localized: "Cargo — Hazardous Cat D", bundle: .module)
		case .cargoReserved75,
			.cargoReserved76,
			.cargoReserved77,
			.cargoReserved78:
			return String(localized: "Cargo — Reserved", bundle: .module)
		case .cargoNoAdditional: return String(localized: "Cargo", bundle: .module)
		case .tanker: return String(localized: "Tanker", bundle: .module)
		case .tankerHazardousA: return String(localized: "Tanker — Hazardous Cat A", bundle: .module)
		case .tankerHazardousB: return String(localized: "Tanker — Hazardous Cat B", bundle: .module)
		case .tankerHazardousC: return String(localized: "Tanker — Hazardous Cat C", bundle: .module)
		case .tankerHazardousD: return String(localized: "Tanker — Hazardous Cat D", bundle: .module)
		case .tankerReserved85,
			.tankerReserved86,
			.tankerReserved87,
			.tankerReserved88:
			return String(localized: "Tanker — Reserved", bundle: .module)
		case .tankerNoAdditional: return String(localized: "Tanker", bundle: .module)
		case .otherType: return String(localized: "Other", bundle: .module)
		case .otherHazardousA: return String(localized: "Other — Hazardous Cat A", bundle: .module)
		case .otherHazardousB: return String(localized: "Other — Hazardous Cat B", bundle: .module)
		case .otherHazardousC: return String(localized: "Other — Hazardous Cat C", bundle: .module)
		case .otherHazardousD: return String(localized: "Other — Hazardous Cat D", bundle: .module)
		case .otherReserved95,
			.otherReserved96,
			.otherReserved97,
			.otherReserved98:
			return String(localized: "Other — Reserved", bundle: .module)
		case .otherNoAdditional: return String(localized: "Other", bundle: .module)
		}
	}
}

/// AIS message type (1–27).
public enum AisMessageType: Int, Sendable, Equatable {
	case positionReportClassA = 1
	case positionReportClassAAssigned = 2
	case positionReportClassAResponse = 3
	case baseStationReport = 4
	case staticAndVoyageData = 5
	case binaryAddressedMessage = 6
	case binaryAcknowledge = 7
	case binaryBroadcastMessage = 8
	case standardSARAircraftReport = 9
	case utcAndDateInquiry = 10
	case utcAndDateResponse = 11
	case addressedSafetyMessage = 12
	case safetyAcknowledge = 13
	case safetyBroadcastMessage = 14
	case interrogation = 15
	case assignmentModeCommand = 16
	case dgnssFixData = 17
	case standardClassBReport = 18
	case extendedClassBReport = 19
	case dataLinkManagement = 20
	case aidToNavigationReport = 21
	case channelManagement = 22
	case groupAssignment = 23
	case classAStaticData = 24
	case singleSlotBinaryMessage = 25
	case multipleSlotBinaryMessage = 26
	case positionReportForLongRange = 27

	/// A human-readable label suitable for display.
	public var label: String {
		switch self {
		case .positionReportClassA: return "Position Report Class A"
		case .positionReportClassAAssigned: return "Position Report Class A (Assigned)"
		case .positionReportClassAResponse: return "Position Report Class A (Response)"
		case .baseStationReport: return "Base Station Report"
		case .staticAndVoyageData: return "Static and Voyage Data"
		case .binaryAddressedMessage: return "Binary Addressed Message"
		case .binaryAcknowledge: return "Binary Acknowledge"
		case .binaryBroadcastMessage: return "Binary Broadcast Message"
		case .standardSARAircraftReport: return "Standard SAR Aircraft Position Report"
		case .utcAndDateInquiry: return "UTC / Date Inquiry"
		case .utcAndDateResponse: return "UTC / Date Response"
		case .addressedSafetyMessage: return "Addressed Safety Message"
		case .safetyAcknowledge: return "Safety Acknowledge"
		case .safetyBroadcastMessage: return "Safety Broadcast Message"
		case .interrogation: return "Interrogation"
		case .assignmentModeCommand: return "Assignment Mode Command"
		case .dgnssFixData: return "DGNSS Fix Data"
		case .standardClassBReport: return "Standard Class B CS Position Report"
		case .extendedClassBReport: return "Extended Class B Equipment Position Report"
		case .dataLinkManagement: return "Data Link Management"
		case .aidToNavigationReport: return "Aid-to-Navigation Report"
		case .channelManagement: return "Channel Management"
		case .groupAssignment: return "Group Assignment Command"
		case .classAStaticData: return "Class A Static Data"
		case .singleSlotBinaryMessage: return "Single Slot Binary Message"
		case .multipleSlotBinaryMessage: return "Multiple Slot Binary Message"
		case .positionReportForLongRange: return "Position Report for Long-Range Applications"
		}
	}
}

/// AIS aid-to-navigation type (message type 21).
public enum NavigationalAidType: Int, Sendable, Equatable {
	case defaultUnspecified = 0
	case referencePoint = 1
	case racon = 2
	case fixedStructure = 3
	case spare4 = 4
	case lightNoSectors = 5
	case lightWithSectors = 6
	case leadingLightFront = 7
	case leadingLightRear = 8
	case beaconCardinalN = 9
	case beaconCardinalE = 10
	case beaconCardinalS = 11
	case beaconCardinalW = 12
	case beaconPortHand = 13
	case beaconStarboardHand = 14
	case beaconPreferredChannelPortHand = 15
	case beaconPreferredChannelStarboardHand = 16
	case beaconIsolatedDanger = 17
	case beaconSafeWater = 18
	case beaconSpecialMark = 19
	case beaconLightVessel = 20
	case lanby = 21
	case buoyCardinalN = 22
	case buoyCardinalE = 23
	case buoyCardinalS = 24
	case buoyCardinalW = 25
	case buoyPortHand = 26
	case buoyStarboardHand = 27
	case buoyPreferredChannelPortHand = 28
	case buoyPreferredChannelStarboardHand = 29
	case buoyIsolatedDanger = 30
	case buoySafeWater = 31

	/// A human-readable label suitable for display.
	public var label: String {
		switch self {
		case .defaultUnspecified: return String(localized: "Unspecified", bundle: .module)
		case .referencePoint: return String(localized: "Reference Point", bundle: .module)
		case .racon: return String(localized: "RACON", bundle: .module)
		case .fixedStructure: return String(localized: "Fixed Structure", bundle: .module)
		case .spare4: return String(localized: "Spare", bundle: .module)
		case .lightNoSectors: return String(localized: "Light (no sectors)", bundle: .module)
		case .lightWithSectors: return String(localized: "Light (with sectors)", bundle: .module)
		case .leadingLightFront: return String(localized: "Leading Light — Front", bundle: .module)
		case .leadingLightRear: return String(localized: "Leading Light — Rear", bundle: .module)
		case .beaconCardinalN: return String(localized: "Beacon — Cardinal N", bundle: .module)
		case .beaconCardinalE: return String(localized: "Beacon — Cardinal E", bundle: .module)
		case .beaconCardinalS: return String(localized: "Beacon — Cardinal S", bundle: .module)
		case .beaconCardinalW: return String(localized: "Beacon — Cardinal W", bundle: .module)
		case .beaconPortHand: return String(localized: "Beacon — Port Hand", bundle: .module)
		case .beaconStarboardHand: return String(localized: "Beacon — Starboard Hand", bundle: .module)
		case .beaconPreferredChannelPortHand: return String(localized: "Beacon — Preferred Channel Port Hand", bundle: .module)
		case .beaconPreferredChannelStarboardHand: return String(localized: "Beacon — Preferred Channel Starboard Hand", bundle: .module)
		case .beaconIsolatedDanger: return String(localized: "Beacon — Isolated Danger", bundle: .module)
		case .beaconSafeWater: return String(localized: "Beacon — Safe Water", bundle: .module)
		case .beaconSpecialMark: return String(localized: "Beacon — Special Mark", bundle: .module)
		case .beaconLightVessel: return String(localized: "Beacon — Light Vessel / LANBY", bundle: .module)
		case .lanby: return String(localized: "LANBY", bundle: .module)
		case .buoyCardinalN: return String(localized: "Buoy — Cardinal N", bundle: .module)
		case .buoyCardinalE: return String(localized: "Buoy — Cardinal E", bundle: .module)
		case .buoyCardinalS: return String(localized: "Buoy — Cardinal S", bundle: .module)
		case .buoyCardinalW: return String(localized: "Buoy — Cardinal W", bundle: .module)
		case .buoyPortHand: return String(localized: "Buoy — Port Hand", bundle: .module)
		case .buoyStarboardHand: return String(localized: "Buoy — Starboard Hand", bundle: .module)
		case .buoyPreferredChannelPortHand: return String(localized: "Buoy — Preferred Channel Port Hand", bundle: .module)
		case .buoyPreferredChannelStarboardHand: return String(localized: "Buoy — Preferred Channel Starboard Hand", bundle: .module)
		case .buoyIsolatedDanger: return String(localized: "Buoy — Isolated Danger", bundle: .module)
		case .buoySafeWater: return String(localized: "Buoy — Safe Water", bundle: .module)
		}
	}
}

/// AIS special manoeuvre indicator (message types 1/2/3 field).
public enum ManeuverIndicator: Int, Sendable, Equatable {
	case notAvailable = 0
	case noSpecial = 1
	case specialManeuver = 2

	/// A human-readable label suitable for display.
	public var label: String {
		switch self {
		case .notAvailable: return String(localized: "Not Available", bundle: .module)
		case .noSpecial: return String(localized: "No Special Manoeuvre", bundle: .module)
		case .specialManeuver: return String(localized: "Special Manoeuvre", bundle: .module)
		}
	}
}
