import 'package:analyzer/dart/ast/ast.dart' as dart;
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:collection/collection.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:sqlparser/sqlparser.dart';

import '../../backend.dart';
import '../../driver/error.dart';
import '../../driver/state.dart';
import '../../results/results.dart';
import '../dart/helper.dart';
import '../resolver.dart';
import '../shared/dart_types.dart';
import 'sqlparser/drift_lints.dart';
import 'sqlparser/mapping.dart';

abstract class DriftElementResolver<T extends DiscoveredElement>
    extends LocalElementResolver<T> {
  DriftElementResolver(
      super.file, super.discovered, super.resolver, super.state);

  Future<CustomColumnType?> resolveCustomColumnType(
      InlineDartToken type) async {
    dart.Expression expression;
    try {
      expression = await resolver.driver.backend.resolveExpression(
        file.ownUri,
        type.dartCode,
        file.discovery!.importDependencies
            .map((e) => e.uri.toString())
            .where((e) => e.endsWith('.dart')),
      );
    } on CannotReadExpressionException catch (e) {
      reportError(DriftAnalysisError.inDriftFile(type, e.msg));
      return null;
    }

    final knownTypes = await resolver.driver.knownTypes;
    return readCustomType(
      knownTypes.helperLibrary,
      expression,
      knownTypes,
      (msg) => reportError(DriftAnalysisError.inDriftFile(type, msg)),
    );
  }

  Future<AppliedTypeConverter?> typeConverterFromMappedBy(
      ColumnType sqlType, bool nullable, MappedBy mapper) async {
    final code = mapper.mapper.dartCode;

    dart.Expression expression;
    try {
      expression = await resolver.driver.backend.resolveExpression(
        file.ownUri,
        code,
        file.discovery!.importDependencies
            .map((e) => e.uri.toString())
            .where((e) => e.endsWith('.dart')),
      );
    } on CannotReadExpressionException catch (e) {
      reportError(DriftAnalysisError.inDriftFile(mapper, e.msg));
      return null;
    }

    final knownTypes = await resolver.driver.knownTypes;

    return readTypeConverter(
      knownTypes.helperLibrary,
      expression,
      sqlType,
      nullable,
      (msg) => reportError(DriftAnalysisError.inDriftFile(mapper, msg)),
      knownTypes,
    );
  }

  void reportLints(AnalysisContext context, Iterable<DriftElement> references) {
    context.errors.forEach(reportLint);

    // Also run drift-specific lints on the query
    final linter = DriftSqlLinter(context, references: references)
      ..collectLints();
    linter.sqlParserErrors.forEach(reportLint);
  }

  Future<Element?> _findInDart(String identifier) async {
    final dartImports = file.discovery!.importDependencies
        .map((e) => e.uri)
        .where((importUri) => importUri.path.endsWith('.dart'))
        // Also add `dart:core` as a default import so that types like `Record`
        // are available.
        .followedBy([AnnotatedDartCode.dartCore]);

    return await resolver.driver.backend
        .resolveTopLevelElement(file.ownUri, identifier, dartImports);
  }

  /// Resolves [identifier] to a Dart element declaring a type, or reports an
  /// error if this is not possible.
  ///
  /// The [syntacticSource] will be the base for the error's span.
  Future<DartType?> findDartTypeOrReportError(
      String identifier, SyntacticEntity syntacticSource) async {
    final element = await _findInDart(identifier);

    if (element == null) {
      reportError(
        DriftAnalysisError.inDriftFile(syntacticSource,
            'Could not find `$identifier`, are you missing an import?'),
      );
      return null;
    } else if (element is InterfaceElement) {
      final library = element.library;
      return library.typeSystem.instantiateInterfaceToBounds(
          element: element, nullabilitySuffix: NullabilitySuffix.none);
    } else if (element is TypeAliasElement) {
      final library = element.library;
      return library.typeSystem.instantiateTypeAliasToBounds(
          element: element, nullabilitySuffix: NullabilitySuffix.none);
    } else {
      reportError(DriftAnalysisError.inDriftFile(
        syntacticSource,
        '`$identifier` does not refer to anything defining a type. Expected '
        'a class, a mixin, an interface or a typedef.',
      ));
      return null;
    }
  }

  /// Attempts to find a matching [ExistingRowClass] for a [DriftTableName]
  /// annotation.
  Future<ExistingRowClass?> resolveExistingRowClass(
      List<DriftColumn> columns, DriftTableName source) async {
    assert(source.useExistingDartClass);

    final dataClassName = source.overriddenDataClassName;
    final element = await _findInDart(dataClassName);
    final knownTypes = await resolver.driver.knownTypes;

    FoundDartClass? foundDartClass;

    if (element is InterfaceElement) {
      foundDartClass = FoundDartClass(element, null);
    } else if (element is TypeAliasElement) {
      // Resolve type alias to a class, or use record if we have one.
      final innerType = element.aliasedType;
      if (innerType is InterfaceType) {
        foundDartClass =
            FoundDartClass(innerType.element, innerType.typeArguments);
      } else if (innerType is RecordType) {
        return validateRowClassFromRecordType(
          element,
          columns,
          innerType,
          false,
          this,
          knownTypes,
        );
      }
    }

    if (foundDartClass == null) {
      reportError(DriftAnalysisError.inDriftFile(
        source,
        'Existing Dart class $dataClassName was not found, are '
        'you missing an import?',
      ));
      return null;
    } else {
      return validateExistingClass(columns, foundDartClass,
          source.constructorName ?? '', false, this, knownTypes);
    }
  }

  DriftElement? findInResolved(List<DriftElement> references, String name) {
    return references.firstWhereOrNull((e) => e.id.sameName(name));
  }

  /// Creates a type resolver capable of resolving `ENUM` and `ENUMNAME` types.
  ///
  /// Because actual type resolving work is synchronous, types are pre-resolved
  /// and must be known beforehand. Types can be found by [resolveSqlReferences].
  Future<TypeFromText> createTypeResolver(
    FoundReferencesInSql references,
    KnownDriftTypes helper,
  ) async {
    final typeLiteralToResolved = <String, DartType>{};

    for (final entry in references.dartTypes.entries) {
      final type = await findDartTypeOrReportError(entry.value, entry.key);

      if (type != null) {
        typeLiteralToResolved[entry.value] = type;
      }
    }

    return enumColumnFromText(typeLiteralToResolved, helper);
  }

  void reportLint(AnalysisError parserError) {
    reportError(DriftAnalysisError.fromSqlError(parserError));
  }
}

class FoundReferencesInSql {
  /// All referenced tables in the statement.
  final List<DriftElement> referencedElements;

  /// All inline Dart tokens used in a `MAPPED BY`.
  final List<String> dartExpressions;

  /// All Dart types that were referenced in an `ENUM` or `ENUMNAME` cast
  /// expression in SQL.
  final Map<SyntacticEntity, String> dartTypes;

  const FoundReferencesInSql({
    this.referencedElements = const [],
    this.dartExpressions = const [],
    this.dartTypes = const {},
  });

  static final RegExp enumRegex =
      RegExp(r'^enum(name)?\((\w+)\)$', caseSensitive: false);
}
