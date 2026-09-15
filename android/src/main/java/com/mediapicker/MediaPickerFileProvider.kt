package com.mediapicker

import androidx.core.content.FileProvider

/**
 * A FileProvider subclass exists purely so this module's provider has a unique
 * android:name.
 *
 * The manifest merger keys <provider> elements by android:name, not by
 * authority, so declaring the bare androidx.core.content.FileProvider collides
 * with any other dependency that declares it too, and the consuming app's build
 * fails on the differing android:authorities even though the two authorities
 * could never actually clash at runtime.
 *
 * Nothing else changes: FileProvider.getUriForFile resolves the path strategy
 * from the authority's meta-data, not from the provider class, so the module's
 * capture URIs keep working unmodified.
 */
class MediaPickerFileProvider : FileProvider()
