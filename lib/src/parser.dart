// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library rpc.parser;

import 'dart:async';
import 'dart:mirrors';

import 'package:uri/uri.dart';

import 'annotations.dart';
import 'config.dart';
import 'utils.dart';

class ApiParser {
  // List of all the errors found by the parser.
  final List<ApiConfigError> errors = [];

  final RegExp _pathMatcher = new RegExp(r'\{(.*?)\}');

  final Map<String, List<ApiConfigMethod>> apiMethods = {};

  final Map<String, ApiConfigSchema> apiSchemas = {};

  // Stack of contextual IDs.
  // The id itself is composed of a List<String> to allow for easy adding
  // and removing id segments.
  final List<List<String>> _idStack = [[]];

  // Returns the current id, which is the last in the list (top of the stack).
  String get _contextId => _idStack.last.join('.');

  // Push a new id on the stack.
  void _pushId(String id) {
    _idStack.add([id]);
  }

  // Pop the current id of the stack.
  void _popId() {
    assert(_idStack.isNotEmpty);
    _idStack.removeLast().join('.');
  }

  // Add an id segment to the current id.
  void _addIdSegment(String id) {
    assert(_idStack.isNotEmpty);
    _idStack.last.add(id);
  }

  // Remove the last id segment from the current id.
  String _removeIdSegment() {
    assert(_idStack.isNotEmpty);
    return _idStack.last.removeLast();
  }

  // Changes [name] to lower camel case, used for default names and ids.
  String _camelCaseName(String name) {
    return name.substring(0, 1).toLowerCase() + name.substring(1);
  }

  // Returns the annotation of type 'apiType' if exists and valid.
  // Otherwise returns null.
  dynamic _getMetadata(DeclarationMirror dm, Type apiType) {
    var annotations =
        dm.metadata.where((a) => a.reflectee.runtimeType == apiType).toList();
    if (annotations.length == 0) {
      return null;
    } else if (annotations.length > 1) {
      var name = MirrorSystem.getName(dm.simpleName);
      addError('Multiple ${apiType} annotations on declaration \'$name\'.');
      return null;
    }
    return annotations.first.reflectee;
  }

  void addError(String errorMessage) {
    // TODO: Make it configurable whether to throw or collect the errors.
    rpcLogger.severe('$_contextId: $errorMessage');
    errors.add(new ApiConfigError('$_contextId: $errorMessage'));
  }

  bool get isValid => errors.isEmpty;

  // Parses a top level API class and all reachable resources, methods, and
  // schemas and returns a corresponding ApiConfig instance.
  ApiConfig parse(dynamic api) {
    var apiInstance = reflect(api);
    var apiClass = apiInstance.type;

    // id used for error reporting and part of the discovery doc id for methods.
    var id =  MirrorSystem.getName(apiClass.simpleName);
    _addIdSegment(id);

    // Parse ApiClass annotation.
    ApiClass metaData = _getMetadata(apiClass, ApiClass);
    if (metaData == null) {
      addError('Missing required @ApiClass annotation.');
      metaData = new ApiClass();
    }
    var name = metaData.name;
    if (name == null || name.isEmpty) {
      // Default to class name in camel case.
      name = _camelCaseName(id);
    }
    var version = metaData.version;
    if (version == null || version.isEmpty) {
      addError('@ApiClass.version field is required.');
    }
    // The apiKey is used to match a request against a specific API and version.
    String apiKey = '/$name/$version';

    // Parse API resources and methods.
    var resources = _parseResources(apiInstance);
    var methods = _parseMethods(apiInstance);

    var apiConfig = new ApiConfig(apiKey, name, version, metaData.title,
                                  metaData.description, resources, methods,
                                  apiSchemas, apiMethods);
    _removeIdSegment();
    assert(_contextId.isEmpty);
    return apiConfig;
  }

  // Scan through all class instance fields and parse the one's annotated
  // with @ApiResource.
  Map<String, ApiConfigResource> _parseResources(InstanceMirror classInstance) {
    var resources= {};

    // Scan through the class instance's declarations and parse fields annotated
    // with the @ApiResource annotation.
    classInstance.type.declarations.values.forEach((dm) {
      var metadata = _getMetadata(dm, ApiResource);
      if (metadata == null) return;  // Not a valid ApiResource.

      var fieldName = MirrorSystem.getName(dm.simpleName);
      if (dm is! VariableMirror) {
        // Only fields can have an @ApiResource annotation.
        addError('@ApiResource annotation on non-field: \'$fieldName\'');
        return;
      }

      // Parse resource and add it to the map of resources for the containing
      // class.
      var resourceInstance = classInstance.getField(dm.simpleName);
      ApiConfigResource resourceConfig =
          parseResource(fieldName, resourceInstance, metadata);
      if (resources.containsKey(resourceConfig.name)) {
        addError('Duplicate resource with name: ${resourceConfig.name}');
      } else {
        resources[resourceConfig.name] = resourceConfig;
      }
    });
    return resources;
  }

  // Parse a specific resource's sub resources and methods and return an
  // ApiConfigResource.
  ApiConfigResource parseResource(String defaultResourceName,
                                  InstanceMirror resourceInstance,
                                  ApiResource metadata) {
    var id = _camelCaseName(defaultResourceName);
    _addIdSegment(id);

    // Recursively parse API sub resources and methods on this resourceInstance.
    var resources = _parseResources(resourceInstance);
    var methods = _parseMethods(resourceInstance);

    var name = metadata.name;
    if (name == null) {
    // The default name is the camel-case version of the default resource name.
      name =  id;
    }
    _removeIdSegment();

    return new ApiConfigResource(name, resources, methods);
  }

  // Parse a specific instance's methods and return a list of ApiConfigMethod's
  // corresponding to each of the method's annotated with @ApiMethod.
  List<ApiConfigMethod> _parseMethods(InstanceMirror classInstance) {
    var methods = [];
    // Parse all methods annotated with the @ApiMethod annotation on this class
    // instance.
    classInstance.type.declarations.values.forEach((dm) {
      var metadata = _getMetadata(dm, ApiMethod);
      if (metadata == null) return null;

      if (dm is! MethodMirror || !dm.isRegularMethod) {
        // The @ApiMethod annotation is only supported on regular methods.
        var name = MirrorSystem.getName(dm.simpleName);
        addError('@ApiMethod annotation on non-method declaration: \'$name\'');
      }

      var method = parseMethod(dm, metadata, classInstance);
      methods.add(method);
    });
    return methods;
  }

  // Parse a specific method, including parameters and return type, and return
  // the corresponding ApiConfigMethod.
  ApiConfigMethod parseMethod(MethodMirror mm,
                              ApiMethod metadata,
                              InstanceMirror methodOwner) {
    const List<String> allowedMethods =
        const ['GET', 'DELETE', 'PUT', 'POST', 'PATCH'];

    // Method name is used for error reporting and as a default for the
    // name in the discovery document.
    var methodName = _camelCaseName(MirrorSystem.getName(mm.simpleName));
    _addIdSegment(methodName);

    // Parse name.
    var name = metadata.name;
    if (name == null || name.isEmpty) {
      // Default method name is method name in camel case.
      name = methodName;
    }

    // Method discovery document id.
    var discoveryId = _contextId;

    // Validate method path.
    if (metadata.path == null || metadata.path.isEmpty) {
      addError('ApiMethod.path field is required.');
    } else if (metadata.path.startsWith('/')) {
      addError('path cannot start with \'/\'.');
    }

    // Parse HTTP method.
    var httpMethod = metadata.method.toUpperCase();
    if (!allowedMethods.contains(httpMethod)) {
      addError('Unknown HTTP method: ${httpMethod}.');
    }

    // Setup a uri parser used to match a uri to this method.
    var parser;
    try {
      parser = new UriParser(new UriTemplate('${metadata.path}'));
    } catch (e) {
      addError('Invalid path: ${metadata.path}. Failed with error: $e');
    }

    // Parse method parameters. Path parameters must be parsed first followed by
    // either the query string parameters or the request schema.
    var pathParams;
    var queryParams;
    var requestSchema;
    if (metadata.path != null) {
      pathParams = _parsePathParameters(mm, metadata.path);
      if (bodyLessMethods.contains(httpMethod)) {
        // If this is a method without body it can have named parameters
        // passed via the query string. Basically any named parameter following
        // the path parameters can be passed via the request's query string.
        queryParams = _parseQueryParameters(mm, pathParams.length);
      } else {
        // Methods with a body must have exactly one additional parameter,
        // namely the class parameter corresponding to the request body.
        requestSchema =
            _parseMethodRequestParameter(mm, httpMethod, pathParams.length);
      }
    }

    // Parse method return type.
    var responseSchema = _parseMethodReturnType(mm);

    var methodConfig = new ApiConfigMethod(discoveryId, methodOwner,
        mm.simpleName, name, metadata.path, httpMethod, metadata.description,
        pathParams, queryParams, requestSchema, responseSchema, parser);

    _setupApiMethod(methodConfig);

    _removeIdSegment();
    return methodConfig;
  }

  // Parses a method's url path parameters and validates them against the
  // method signature.
  List<ApiParameter> _parsePathParameters(MethodMirror mm, String path) {
    var pathParams = [];
    if (path == null) return pathParams;

    // Parse the path to get the number and order of the path parameters
    // and to validate the same order is given in the method signature.
    // The path parameters must be parsed before the query or request
    // parameters since the number of path parameters is needed.
    var parsedPathParams = _pathMatcher.allMatches(path);
    if (parsedPathParams.length > 0 &&
        (mm.parameters == null ||
         mm.parameters.length < parsedPathParams.length)) {
        addError('Missing methods parameters specified in method path: $path.');
        // We don't process the method mirror if not enough parameters.
        return pathParams;
    }
    for (int i = 0; i < parsedPathParams.length; ++i) {
      var pm = mm.parameters[i];
      var pathParamName = parsedPathParams.elementAt(i).group(1);
      var methodParamName = MirrorSystem.getName(pm.simpleName);
      if (methodParamName != pathParamName) {
        addError(
            'Expected method parameter with name \'$pathParamName\', but found'
            ' parameter with name \'$methodParamName\'.');
      }
      if (pm.isOptional || pm.isNamed) {
        addError('No support for optional path parameters in API methods.');
      }
      if (pm.type.simpleName != #int && pm.type.simpleName != #String) {
        addError(
            'Path parameter \'$pathParamName\' must be of type int or String.');
      }
      pathParams.add(new ApiParameter(pathParamName, pm));
    }
    return pathParams;
  }

  // Validates that all remaining method parameters are named parameters.
  // Returns a map with the name and symbol of the parameter. The parameters
  // are (optionally) passed via the request's query string parameters on
  // invocation.
  List<ApiParameter> _parseQueryParameters(MethodMirror mm,
                                           int queryParamIndex) {
    var queryParams = [];
    for (int i = queryParamIndex; i < mm.parameters.length; ++i) {
      var pm = mm.parameters[i];
      var paramName = MirrorSystem.getName(pm.simpleName);
      if (!pm.isNamed) {
        addError(
            'Non-path parameter \'$paramName\' must be a named parameter.');
      }
      if (pm.type.simpleName != #int && pm.type.simpleName != #String) {
        addError(
            'Query parameter \'$paramName\' must be of type int or String.');
      }
      queryParams.add(new ApiParameter(paramName, pm));
    }
    return queryParams;
  }

  // Parses the method's request parameter. Only called for methods using the
  // POST HTTP method.
  ApiConfigSchema _parseMethodRequestParameter(MethodMirror mm,
                                               String httpMethod,
                                               int requestParamIndex) {
    if (mm.parameters.length  != requestParamIndex + 1) {
      addError('API methods using $httpMethod must have a signature of path '
               'parameters followed by one request parameter.');
      return null;
    }

    // Validate the request parameter, following the path parameters.
    var requestParam = mm.parameters[requestParamIndex];
    if (requestParam.isNamed || requestParam.isOptional) {
      addError('Request parameter cannot be optional or named.');
    }
    var requestType = requestParam.type;

    // Check if the request type is a List or Map and handle that explicitly.
    if (requestType.originalDeclaration == reflectClass(List)) {
      return parseListSchema(requestType);
    }
    if (requestType.originalDeclaration == reflectClass(Map)) {
      return parseMapSchema(requestType);
    }
    if (requestType is! ClassMirror ||
        requestType.simpleName == #dynamic ||
        requestType.isAbstract) {
      addError('API Method parameter has to be an instantiable class.');
      return null;
    }
    return parseSchema(requestType);
  }

  // Parses a method's return type and returns the equivalent ApiConfigSchema.
  ApiConfigSchema _parseMethodReturnType(MethodMirror mm) {
    var returnType = mm.returnType;
    if (returnType.isSubtypeOf(reflectType(Future))) {
      var types = returnType.typeArguments;
      if (types.length == 1) {
        returnType = types[0];
      } else {
        addError('Future return type has to have exactly one non-dynamic type '
                 'parameter.');
        return null;
      }
    }
    // Note: I cannot use #void to get the symbol since void is a keyword.
    if (returnType.simpleName == const Symbol('void')) {
      addError(
          'API Method cannot be void, use VoidMessage as return type instead.');
      return null;
    }
    if (returnType.simpleName == #bool ||
        returnType.simpleName == #int  ||
        returnType.simpleName == #num  ||
        returnType.simpleName == #double ||
        returnType.simpleName == #String) {
      addError('Return type: ${MirrorSystem.getName(returnType.simpleName)} '
               'is not a valid return type.');
      return null;
    }
    // Check if the return type is a List or Map and handle that explicitly.
    if (returnType.originalDeclaration == reflectClass(List)) {
      return parseListSchema(returnType);
    }
    if (returnType.originalDeclaration == reflectClass(Map)) {
      return parseMapSchema(returnType);
    }
    if (returnType is! ClassMirror ||
        returnType.simpleName == #dynamic ||
        returnType.isAbstract) {
      addError('API Method return type has to be a instantiable class.');
      return null;
    }
    return parseSchema(returnType);
  }

  // Adds the given method to the API's set of methods that can be invoked and
  // validates there is no conflict with existing methods already in the API.
  void _setupApiMethod(ApiConfigMethod method) {
    if (method.path == null) {
      assert(!isValid);
      return;
    }
    var methodPathSegments = method.path.split('/');
    var methodKey = '${method.httpMethod}${methodPathSegments.length}';

    // Check for duplicates.
    //
    // For a given http method type (GET, POST, etc.) a method path can only
    // conflict/be ambiguous with another method path that has the same number
    // of path segments. This relies on path parameters being required.
    //
    // All existing methods are grouped by their http method plus their number
    // of path segments.
    // E.g. GET a/{b}/c will be in the _methodMap group with key 'GET3'.
    //
    // The only way to ensure that two methods within the same group are not
    // ambiguous is if they have at least one non-parameter path segment in the
    // same location that does not match each other. That check is done by the
    // conflictingPaths method call.
    var existingMethods = apiMethods.putIfAbsent(methodKey, () => []);
    for (ApiConfigMethod existingMethod in existingMethods) {
      List<String> existingMethodPathSegments = existingMethod.path.split('/');
      if (_conflictingPaths(methodPathSegments, existingMethodPathSegments)) {
        addError('Method path: ${method.path} conflicts with existing method: '
                 '${existingMethod.id} with path: ${existingMethod.path}');
      }
    }
    existingMethods.add(method);
  }

  // Given two method uri paths (as a list of path segments) validates the paths
  // are not conflicting. They conflict if all the non-variable path segments
  // are equal. If one of the non-variable path segments are different there is
  // no conflict since we can always distinguish one from the other.
  bool _conflictingPaths(List<String> pathSegments1,
                         List<String> pathSegments2) {
    assert(pathSegments1.length == pathSegments2.length);
    for (int i = 0; i < pathSegments1.length; ++i) {
      if (!pathSegments1[i].startsWith('{') &&
          !pathSegments2[i].startsWith('{') &&
          pathSegments1[i] != pathSegments2[i]) {
        return false;
      }
    }
    return true;
  }

  // Parses a class as a schema and returns the corresponding ApiConfigSchema.
  // Adds the schema to the API's set of valid schemas.
  ApiConfigSchema parseSchema(ClassMirror schemaClass) {
    // TODO: Add support for ApiSchema annotation for overriding default name.
    var name = MirrorSystem.getName(schemaClass.simpleName);
    _pushId(name);

    ApiConfigSchema schemaConfig = apiSchemas[name];
    if (schemaConfig != null) {
      if (schemaConfig.schemaClass.originalDeclaration !=
          schemaClass.originalDeclaration) {
        var newSchemaName = MirrorSystem.getName(schemaClass.qualifiedName);
        var existingSchemaName =
            MirrorSystem.getName(schemaConfig.schemaClass.qualifiedName);
        addError('Schema \'$newSchemaName\' has a name conflict with '
                 '\'$existingSchemaName\'.');
        _popId();
        return null;
      }
      if (!schemaConfig.propertiesInitialized) {
        // This schema is in the process of parsing its properties. Just return
        // its reference.
        assert(!schemaConfig.containsData);
      }
      _popId();
      return schemaConfig;
    }

    // Check the schema class has an unnamed default constructor.
    var methods = schemaClass.declarations.values.where(
        (mm) => mm is MethodMirror && mm.isConstructor);
    if (!methods.isEmpty && methods.where(
        (mm) => mm.simpleName == schemaClass.simpleName).isEmpty) {
      addError('Schema \'$name\' must have an unnamed constructor.');
    }
    schemaConfig = new ApiConfigSchema(name, schemaClass);

    // We put in the schema before parsing properties to detect cycles.
    apiSchemas[name] = schemaConfig;
    var properties = _parseProperties(schemaClass);
    schemaConfig.initProperties(properties);
    _popId();

    return schemaConfig;
  }

  // Computes a unique canonical name for Lists and Maps.
  String canonicalName(TypeMirror type) {
    if (type.originalDeclaration == reflectClass(List)) {
      return 'ListOf' + canonicalName(type.typeArguments[0]);
    } else if (type.originalDeclaration == reflectClass(Map)) {
      return 'MapOf' + canonicalName(type.typeArguments[1]);
    }
    return MirrorSystem.getName(type.simpleName);
  }

  // Parses a list class as a schema and returns the corresponding ListSchema.
  // Adds the schema to the API's set of valid schemas.
  NamedListSchema parseListSchema(ClassMirror schemaClass) {
    assert(schemaClass.originalDeclaration == reflectClass(List));
    assert(schemaClass.typeArguments.length == 1);
    var itemsType = schemaClass.typeArguments[0];
    var name = canonicalName(schemaClass);
    _pushId(name);

    ApiConfigSchema existingSchemaConfig = apiSchemas[name];
    if (existingSchemaConfig != null) {
      // We explicitly want the two to be the same bound class or we will fail.
      if (existingSchemaConfig.schemaClass != schemaClass) {
        var newSchemaName = MirrorSystem.getName(schemaClass.qualifiedName);
        var existingSchemaName = MirrorSystem.getName(
            existingSchemaConfig.schemaClass.qualifiedName);
        addError('Schema \'$newSchemaName\' has a name conflict with '
                 '\'$existingSchemaName\'.');
        existingSchemaConfig = null;
      }
      _popId();
      return existingSchemaConfig;
    }

    var schemaConfig = new NamedListSchema(name, schemaClass);
    // We put in the schema before parsing properties to detect cycles.
    apiSchemas[name] = schemaConfig;
    var itemsProperty =
        parseProperty(itemsType, '${name}Property', new ApiProperty());
    schemaConfig.initItemsProperty(itemsProperty);
    _popId();

    return schemaConfig;
  }

  // Parses a map class as a schema and returns the corresponding MapSchema.
  // Adds the schema to the API's set of valid schemas.
  NamedMapSchema parseMapSchema(ClassMirror schemaClass) {
    assert(schemaClass.originalDeclaration == reflectClass(Map));
    assert(schemaClass.typeArguments.length == 2);
    var additionalType = schemaClass.typeArguments[1];
    var name = canonicalName(schemaClass);
    _pushId(name);
    if (schemaClass.typeArguments[0].reflectedType != String) {
      addError('Maps must have keys of type \'String\'.');
      _popId();
      return null;
    }

    ApiConfigSchema existingSchemaConfig = apiSchemas[name];
    if (existingSchemaConfig != null) {
      // We explicitly want the two to be the same bound class or we will fail.
      if (existingSchemaConfig.schemaClass != schemaClass) {
        var newSchemaName = MirrorSystem.getName(schemaClass.qualifiedName);
        var existingSchemaName = MirrorSystem.getName(
            existingSchemaConfig.schemaClass.qualifiedName);
        addError('Schema \'$newSchemaName\' has a name conflict with '
                 '\'$existingSchemaName\'.');
        existingSchemaConfig = null;
      }
      _popId();
      return existingSchemaConfig;
    }

    var schemaConfig = new NamedMapSchema(name, schemaClass);
    // We put in the schema before parsing properties to detect cycles.
    apiSchemas[name] = schemaConfig;
    var additionalProperty =
        parseProperty(additionalType, '${name}Property', new ApiProperty());
    schemaConfig.initAdditionalProperty(additionalProperty);
    _popId();

    return schemaConfig;
  }

  // Runs through all fields on a schema class and parses them accordingly.
  Map<Symbol, ApiConfigSchemaProperty> _parseProperties(
      ClassMirror schemaClass) {
    var properties = {};
    schemaClass.declarations.values.forEach((vm) {
      var metadata = _getMetadata(vm, ApiProperty);
      if (metadata == null) {
        // Generate a metadata with default values
        metadata = new ApiProperty();
      }
      if (vm is! VariableMirror || vm.isConst || vm.isPrivate || vm.isStatic) {
        // We only serialize non-const, non-static public fields.
        return;
      }
      var propertyName = metadata.name;
      if (propertyName == null) {
        propertyName = MirrorSystem.getName(vm.simpleName);
      }
      var property = parseProperty(vm.type, propertyName, metadata);
      if (property != null) {
        properties[vm.simpleName] = property;
      }
    });
    return properties;
  }

  // Parse a specific schema property, further dispatching based on the
  // property's type.
  ApiConfigSchemaProperty parseProperty(TypeMirror propertyType,
                                        String propertyName,
                                        ApiProperty metadata) {
    if (propertyType.simpleName == #dynamic) {
      addError('$propertyName: Properties cannot be of type: \'dynamic\'.');
      return null;
    }
    switch (propertyType.reflectedType) {
      case int:
        return parseIntegerProperty(propertyName, metadata);
      case double:
        return parseDoubleProperty(propertyName, metadata);
      case bool:
        return parseBooleanProperty(propertyName, metadata);
      case String:
        if (metadata.values != null && metadata.values.isNotEmpty) {
          return parseEnumProperty(propertyName, metadata);
        }
        return parseStringProperty(propertyName, metadata);
      case DateTime:
        return parseDateTimeProperty(propertyName, metadata);
    }
    // TODO: Could support list and maps that are subclasses rather
    // than only the specific Dart List and Map.
    if (propertyType is ClassMirror && !propertyType.isAbstract) {
      return parseSchemaProperty(propertyName, metadata, propertyType);
    } else if (propertyType.originalDeclaration == reflectClass(List)) {
      return parseListProperty(propertyName, metadata, propertyType);
    } else if (propertyType.originalDeclaration == reflectClass(Map)) {
      return parseMapProperty(propertyName, metadata, propertyType);
    }
    addError('$propertyName: Unsupported property type: '
             '${propertyType.reflectedType}');
    return null;
  }

  // Parses an 'int' property.
  IntegerProperty parseIntegerProperty(String propertyName,
                                       ApiProperty metadata) {
    assert(metadata != null);
    String apiFormat = metadata.format;
    if (apiFormat == null || apiFormat.isEmpty) {
      apiFormat = 'int32';
    }
    String apiType;
    if (apiFormat == 'int32' || apiFormat == 'uint32') {
      apiType = 'integer';
    } else if (apiFormat == 'int64' || apiFormat == 'uint64'){
      apiType = 'string';
    } else {
      addError('$propertyName: Invalid integer variant: $apiFormat. Supported '
               'variants are: int32, uint32, int64, uint64.');
    }
    if (_parseInt(metadata.minValue, apiFormat, propertyName, 'Min') &&
        _parseInt(metadata.maxValue, apiFormat, propertyName, 'Max')) {
      // We only parse the default if min/max are valid since we need them to
      // do the range checking.
      _parseIntDefault(metadata, apiFormat, propertyName);
    }
    return new IntegerProperty(propertyName, metadata.description,
                               metadata.required, metadata.defaultValue,
                               apiType, apiFormat, metadata.minValue,
                               metadata.maxValue);
  }

  // Parses a value to determine if it is a valid integer value.
  // Return true only if the value contains a valid integer.
  bool _parseInt(dynamic value,
                 String format,
                 String name,
                 String messagePrefix) {
    if (value == null) return false;
    if (value is! int) {
      addError('$name: $messagePrefix value must be of type: int.');
      return false;
    } else if (format == 'int32' && value != value.toSigned(32) ||
               format == 'uint32' && value != value.toUnsigned(32) ||
               format == 'int64' && value != value.toSigned(64) ||
               format == 'uint64' && value != value.toUnsigned(64)) {
      addError(
          '$name: $messagePrefix value must be in the range of an \'$format\'');
      return false;
    }
    return true;
  }

  _parseIntDefault(ApiProperty metadata, String format, String name) {
    var defaultValue = metadata.defaultValue;
    if (!_parseInt(metadata.defaultValue, format, name, 'Default')) {
      // If no defaultValue, just return.
      return;
    }
    if (metadata.minValue != null && defaultValue < metadata.minValue) {
      addError('$name: Default value must be >= ${metadata.minValue}.');
    }
    if (metadata.maxValue != null && defaultValue > metadata.maxValue) {
      addError('$name: Default value must be <= ${metadata.maxValue}.');
    }
  }

  // Parses a 'double' property.
  DoubleProperty parseDoubleProperty(String propertyName,
                                     ApiProperty metadata) {
    assert(metadata != null);
    String apiFormat = metadata.format;
    if (apiFormat == null || apiFormat == '') {
      apiFormat = 'double';
    }
    if (apiFormat != 'double' && apiFormat != 'float') {
      addError('$propertyName: Invalid double variant: \'$apiFormat\'. Must be '
          'either \'double\' or \'float\'.');
    }
    if (metadata.defaultValue != null && metadata.defaultValue is! double) {
      addError('$propertyName: DefaultValue must be of type \'double\'.');
    }
    return new DoubleProperty(propertyName, metadata.description,
                              metadata.required, metadata.defaultValue,
                              apiFormat);
  }

  // Parses a 'bool' property.
  BooleanProperty parseBooleanProperty(String propertyName,
                                       ApiProperty metadata) {
    assert(metadata != null);
    const List<Symbol> extraFields = const [#defaultValue];
    _checkValidFields(propertyName, 'bool', metadata, extraFields);
    if (metadata.defaultValue != null && metadata.defaultValue is! bool) {
      addError('$propertyName: Default value: ${metadata.defaultValue} must be '
               'boolean \'true\' or \'false\'.');
    }
    return new BooleanProperty(propertyName, metadata.description,
                               metadata.required, metadata.defaultValue);
  }

  // Parses an 'enum' property.
  EnumProperty parseEnumProperty(String propertyName,
                                 ApiProperty metadata) {
    assert(metadata != null);
    const List<Symbol> extraFields = const [#defaultValue, #values];
    _checkValidFields(propertyName, 'Enum', metadata, extraFields);
    var defaultValue = metadata.defaultValue;
    if (defaultValue != null &&
        (defaultValue is! String ||
         !metadata.values.containsKey(defaultValue))) {
      addError('$propertyName: Default value: $defaultValue must be one of the '
               'valid enum values: ${metadata.values.keys.toString()}.');
    }
    return new EnumProperty(propertyName, metadata.description,
                            metadata.required, metadata.defaultValue,
                            metadata.values);
  }

  // Parses a 'String' property.
  StringProperty parseStringProperty(String propertyName,
                                     ApiProperty metadata) {
    assert(metadata != null);
    const List<Symbol> extraFields = const [#defaultValue];
    _checkValidFields(propertyName, 'String', metadata, extraFields);
    if (metadata.defaultValue != null && metadata.defaultValue is! String) {
      addError('$propertyName: Default value: ${metadata.defaultValue} must be '
               'of type \'String\'.');
    }
    return new StringProperty(propertyName, metadata.description,
                              metadata.required, metadata.defaultValue);
  }

  // Parses a 'DateTime' property.
  DateTimeProperty parseDateTimeProperty(String propertyName,
                                         ApiProperty metadata) {
    assert(metadata != null);
    if (metadata.defaultValue != null && metadata.defaultValue is! DateTime) {
      addError('$propertyName: Default value ${metadata.defaultValue} must be '
               'of type \'DateTime\'.');
    }
    return new DateTimeProperty(propertyName, metadata.description,
                                metadata.required, metadata.defaultValue);
  }

  // Parses a nested class schema property.
  SchemaProperty parseSchemaProperty(String propertyName,
                                     ApiProperty metadata,
                                     ClassMirror schemaTypeMirror) {
    assert(metadata != null);
    assert(schemaTypeMirror is ClassMirror && !schemaTypeMirror.isAbstract);
    if (metadata.defaultValue != null) {
      addError('$propertyName: Default value not supported for non-primitive '
               'types.');
    }
    var schema = parseSchema(schemaTypeMirror);
    return new SchemaProperty(propertyName, metadata.description,
                              metadata.required, schema);
  }

  ListProperty parseListProperty(String propertyName,
                                 ApiProperty metadata,
                                 ClassMirror listPropertyType) {
    var listTypeArguments = listPropertyType.typeArguments;
    assert(listTypeArguments.length == 1);
    // TODO: Figure out what to do about metadata for the items property.
    var listItemsProperty =
        parseProperty(listTypeArguments[0], propertyName, new ApiProperty());
    return new ListProperty(propertyName, metadata.description,
                            metadata.required, listItemsProperty);
  }

  MapProperty parseMapProperty(String propertyName,
                               ApiProperty metadata,
                               ClassMirror mapPropertyType) {
    var mapTypeArguments = mapPropertyType.typeArguments;
    assert(mapTypeArguments.length == 2);
    if (mapTypeArguments[0].reflectedType != String) {
      addError('$propertyName: Maps must have keys of type \'String\'.');
    }
    // TODO: Figure out what to do about metadata for the additional property.
    var additionalProperty =
        parseProperty(mapTypeArguments[1], propertyName, new ApiProperty());
    return new MapProperty(propertyName, metadata.description,
                           metadata.required, additionalProperty);
  }

  // Helper method to check that a field annotated with an ApiProperty is using
  // only the supported ApiProperty fields.
  void _checkValidFields(String propertyName,
                         String propertyTypeName,
                         ApiProperty metadata,
                         List<Symbol> extraFields) {
    const List<Symbol> commonFields = const [#name, #description, #required];
    InstanceMirror im = reflect(metadata);
    im.type.declarations.forEach((Symbol field, DeclarationMirror fieldMirror) {
      if (fieldMirror is !VariableMirror || commonFields.contains(field)) {
        return;
      }
      String fieldName = MirrorSystem.getName(field);
      if (im.getField(field).reflectee != null &&
          !extraFields.contains(field)) {
        addError('$propertyName: Invalid property annotation. Property of type '
                 '$propertyTypeName does not support the ApiProperty field: '
                 '$fieldName');
      }
    });
  }
}