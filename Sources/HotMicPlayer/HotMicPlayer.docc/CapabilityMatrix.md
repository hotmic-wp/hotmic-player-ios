# Capability matrix

Map a vertical and horizontal video experience to the SDK and the host integration.

| Requirement category | API / component | Host owns |
| --- | --- | --- |
| Full-screen and on-screen UI | `HMVerticalFeedView`, `HMPlayerView`, `enterFullscreen` / `exitFullscreen`, `HMSocialPlayerView`, rail/metadata/sheet replacement slots | App navigation, branding, share presentation, supported orientations, custom chrome |
| Core controls | `play`, `pause`, `seek(to:)`, `isMuted`, snapshots, `hmVideoGestures`, `HMProgressBar`, CC APIs | Control visibility, custom scrubber interactions, autoplay policy and analytics consent |
| Social layer | `HMSocialDataSource` / `HMSocialModel`, `HMEngagementSocialAdapter`, `HMActionRail`, `HMMetadataView`, `HMCommentPreview`, `HMFireBurst`, `HMCountFormatter` | Backend, stable IDs, membership and counts, share/comments routing, custom rail and metadata when chosen |
| Squeezeback | `hmVideoLayout`, `HMVideoInsets`, `squeezeTarget`, `HMSocialState`, `HMCommentSheet` shell | Host nav height; custom sheet dragging, keyboard clearance and animations on the custom path |
| Ads | `HMAdBreakProvider`, `.preRoll`, `.hostPlayed`, `HMHostAdContext`, `adState`, `adProgress`, `HMOverlayRegions`, sidecar slot | Ad SDK, decisioning, consent, tracking, skip eligibility/countdown, companions and timeout policy |
| Feed and navigation | Atomic playlist edits, `reconcile`, `HMPlaylistSource`, `HMItemResolver`, `next` / `previous` / `jump(toID:)` | Catalog/ranking, pagination transport, persistent tabs, screen visibility/lifetime |
| Accessibility | Native video actions/values, kit labels and Dynamic Type, MediaAccessibility captions, Reduce Motion | Labels/values and 44-point targets for custom/replacement UI, palette contrast, host accessibility QA |
| Horizontal | `.automatic` / fit/fill/backdrop policies, item aspect hint, snapshot `videoFrame`, inline UIKit/SwiftUI and shared-layer fullscreen | Orientation permissions, host container constraints, layout reservations after rotation |

The ready-made and custom UI paths have equal playback capabilities. Your backend can supply the complete engagement contract; the HotMic backend via Connect currently lacks per-stream reactions and paged comment history. See <doc:PartnerIntegrationGuide> and <doc:IntegrationChecklist>.
