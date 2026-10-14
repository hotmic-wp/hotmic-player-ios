# ``HotMicPlayerUI``

Add ready-made engagement components and a themed overlay to a HotMicPlayer feed.

## Overview

This optional iOS 17+ product depends only on HotMicPlayer. Use ``HMSocialPlayerView`` for a ready-made social feed with your backend, ``HMOverlayLayout`` for a replay engagement layout, compose individual components around `HMEngagement`, or conform a view to ``HMEngagementLayout``. Your `HMInteractionSource` supplies the data and supported actions; without one the player has empty, read-only engagement.

All views, layout contexts and interactions run on the main actor. Theme and option values configure SwiftUI on that actor and are not declared `Sendable`.

## Topics

### Guides
- <doc:GettingStarted>
- <doc:ReadyMadeSocialOverlay>
- <doc:Theming>
- <doc:EngagementAndCustomSources>

### Social overlay
- ``HMSocialPlayerView``
- ``HMSocialPlayerViewController``
- ``HMSocialOverlay``
- ``HMSocialDataSource``
- ``HMSocialContent``
- ``HMSocialComment``
- ``HMSocialModel``
- ``HMEngagementSocialAdapter``
- ``HMSocialState``
- ``HMSocialOptions``
- ``HMSocialCallbacks``

### Layouts
- ``HMOverlayLayout``
- ``HMEngagementLayout``
- ``HMEngagementContext``

### Components
- ``HMMetadataView``
- ``HMCommentPreview``
- ``HMFireBurst``
- ``HMProgressBar``
- ``HMCommentSheet``
- ``HMPlayPauseAffordance``
- ``HMShareSheet``
- ``HMChatRail``
- ``HMPollCard``
- ``HMFloatingReactions``
- ``HMActionRail``
- ``HMComposer``
- ``HMEngagementScrubber``

### Theme
- ``HMTheme``
