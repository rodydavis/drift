---
data:
  title: "Using drift classes in other builders"
  description: Configure your build to allow drift dataclasses to be seen by other builders.
template: layouts/docs/single
---

It is possible to use classes generated by drift in other builders.
Due to technicalities related to Dart's build system and `source_gen`, this approach requires a custom configuration
and minor code changes. Put this content in a file called `build.yaml` next to your `pubspec.yaml`:

```yaml
targets:
  $default:
    # disable the default generators, we'll only use the non-shared drift generator here
    auto_apply_builders: false
    builders:
      drift_dev|not_shared:
        enabled: true
        # If needed, you can configure the builder like this:
        # options:
        #   skip_verification_code: true
        #   use_experimental_inference: true
      # This builder is necessary for drift-file preprocessing. You can disable it if you're not
      # using .drift files with type converters.
      drift_dev|preparing_builder:
        enabled: true

  run_built_value:
    dependencies: ['your_package_name']
    builders:
      # Disable drift builders. By default, those would run on each target
      drift_dev:
        enabled: false
      drift_dev|preparing_builder:
        enabled: false
      # we don't need to disable drift|not_shared, because it's disabled by default
```

In all files that use generated drift code, you'll have to replace `part 'filename.g.dart'` with `part 'filename.drift.dart'`.
If you use drift _and_ another builder in the same file, you'll need both `.g.dart` and `.drift.dart` as part-files.

A full example is available as part of [the drift repo](https://github.com/simolus3/drift/tree/develop/examples/with_built_value).

If you run into any problems with this approach, feel free to open an issue on drift.

## The technicalities, explained

Almost all code generation packages use a so called "shared part file" approach provided by `source_gen`.
It's a common protocol that allows unrelated builders to write into the same `.g.dart` file.
For this to work, each builder first writes a `.part` file with its name. For instance, if you used `drift`
and `built_value` in the same project, those part files could be called `.drift.part` and `.built_value.part`.
Later, the common `source_gen` package would merge the part files into a single `.g.dart` file.

This works great for most use cases, but a downside is that each builder can't see the final `.g.dart`
file, or use any classes or methods defined in it. To fix that, drift offers an optional builder -
`drift_dev|not_shared` - that will generate a separate part file only containing
code generated by drift. So most of the work resolves around disabling the default generator of drift
and use the non-shared generator instead.

Finally, we need to the build system to run drift first, and all the other builders otherwise. This is
why we split the builders up into multiple targets. The first target will only run drift, the second
target has a dependency on the first one and will run all the other builders.