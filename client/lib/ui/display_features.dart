import 'dart:ui';

/// Feature facts shared by consumers; width and posture policies stay local.
bool isFoldFeature(DisplayFeature feature) =>
    feature.type == DisplayFeatureType.fold ||
    feature.type == DisplayFeatureType.hinge;

bool isVerticalFeature(DisplayFeature feature) =>
    feature.bounds.width <= feature.bounds.height;

bool isFlatFoldFeature(DisplayFeature feature) =>
    isFoldFeature(feature) && feature.state == DisplayFeatureState.postureFlat;

/// Convert platform bounds when a host moves the content origin.
List<DisplayFeature> translateDisplayFeatures(
  Iterable<DisplayFeature> features,
  Offset offset,
) => <DisplayFeature>[
  for (final DisplayFeature feature in features)
    DisplayFeature(
      bounds: feature.bounds.shift(offset),
      type: feature.type,
      state: feature.state,
    ),
];
