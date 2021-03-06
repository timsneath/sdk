// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import 'package:front_end/src/base/instrumentation.dart';
import 'package:front_end/src/fasta/fasta_codes.dart';
import 'package:front_end/src/fasta/kernel/kernel_shadow_ast.dart';
import 'package:front_end/src/fasta/names.dart' show callName;
import 'package:front_end/src/fasta/problems.dart' show unhandled;
import 'package:front_end/src/fasta/source/source_library_builder.dart';
import 'package:front_end/src/fasta/type_inference/interface_resolver.dart';
import 'package:front_end/src/fasta/type_inference/type_inference_engine.dart';
import 'package:front_end/src/fasta/type_inference/type_inference_listener.dart';
import 'package:front_end/src/fasta/type_inference/type_promotion.dart';
import 'package:front_end/src/fasta/type_inference/type_schema.dart';
import 'package:front_end/src/fasta/type_inference/type_schema_elimination.dart';
import 'package:front_end/src/fasta/type_inference/type_schema_environment.dart';
import 'package:kernel/ast.dart'
    show
        Arguments,
        AsExpression,
        AsyncMarker,
        BottomType,
        Class,
        DartType,
        DispatchCategory,
        DynamicType,
        Expression,
        Field,
        FunctionNode,
        FunctionType,
        Initializer,
        InterfaceType,
        InvocationExpression,
        Member,
        MethodInvocation,
        Name,
        Procedure,
        ProcedureKind,
        PropertyGet,
        PropertySet,
        ReturnStatement,
        Statement,
        SuperMethodInvocation,
        SuperPropertyGet,
        SuperPropertySet,
        ThisExpression,
        TypeParameter,
        TypeParameterType,
        VariableDeclaration,
        VoidType;
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_algebra.dart';

/// Given a [FunctionNode], gets the named parameter identified by [name], or
/// `null` if there is no parameter with the given name.
VariableDeclaration getNamedFormal(FunctionNode function, String name) {
  for (var formal in function.namedParameters) {
    if (formal.name == name) return formal;
  }
  return null;
}

/// Given a [FunctionNode], gets the [i]th positional formal parameter, or
/// `null` if there is no parameter with that index.
VariableDeclaration getPositionalFormal(FunctionNode function, int i) {
  if (i < function.positionalParameters.length) {
    return function.positionalParameters[i];
  } else {
    return null;
  }
}

bool isOverloadableArithmeticOperator(String name) {
  return identical(name, '+') ||
      identical(name, '-') ||
      identical(name, '*') ||
      identical(name, '%');
}

/// Keeps track of information about the innermost function or closure being
/// inferred.
class ClosureContext {
  final bool isAsync;

  final bool isGenerator;

  final DartType returnContext;

  DartType _inferredReturnType;

  factory ClosureContext(TypeInferrerImpl inferrer, AsyncMarker asyncMarker,
      DartType returnContext) {
    bool isAsync = asyncMarker == AsyncMarker.Async ||
        asyncMarker == AsyncMarker.AsyncStar;
    bool isGenerator = asyncMarker == AsyncMarker.SyncStar ||
        asyncMarker == AsyncMarker.AsyncStar;
    if (isGenerator) {
      if (isAsync) {
        returnContext = inferrer.getTypeArgumentOf(
            returnContext, inferrer.coreTypes.streamClass);
      } else {
        returnContext = inferrer.getTypeArgumentOf(
            returnContext, inferrer.coreTypes.iterableClass);
      }
    } else if (isAsync) {
      returnContext = inferrer.wrapFutureOrType(
          inferrer.typeSchemaEnvironment.flattenFutures(returnContext));
    }
    return new ClosureContext._(isAsync, isGenerator, returnContext);
  }

  ClosureContext._(this.isAsync, this.isGenerator, this.returnContext);

  /// Updates the inferred return type based on the presence of a return
  /// statement returning the given [type].
  void handleReturn(TypeInferrerImpl inferrer, DartType type) {
    if (isGenerator) return;
    if (isAsync) {
      type = inferrer.typeSchemaEnvironment.flattenFutures(type);
    }
    _updateInferredReturnType(inferrer, type);
  }

  void handleYield(TypeInferrerImpl inferrer, bool isYieldStar, DartType type) {
    if (!isGenerator) return;
    if (isYieldStar) {
      type = inferrer.getDerivedTypeArgumentOf(
          type,
          isAsync
              ? inferrer.coreTypes.streamClass
              : inferrer.coreTypes.iterableClass);
      if (type == null) return;
    }
    _updateInferredReturnType(inferrer, type);
  }

  DartType inferReturnType(
      TypeInferrerImpl inferrer, bool isExpressionFunction) {
    DartType inferredReturnType =
        inferrer.inferReturnType(_inferredReturnType, isExpressionFunction);
    if (!isExpressionFunction &&
        returnContext != null &&
        !_analyzerSubtypeOf(inferrer, inferredReturnType, returnContext)) {
      // For block-bodied functions, if the inferred return type isn't a
      // subtype of the context, we use the context.  We use analyzer subtyping
      // rules here.
      // TODO(paulberry): this is inherited from analyzer; it's not part of
      // the spec.  See also dartbug.com/29606.
      inferredReturnType = greatestClosure(inferrer.coreTypes, returnContext);
    } else if (isExpressionFunction &&
        returnContext != null &&
        inferredReturnType is DynamicType) {
      // For expression-bodied functions, if the inferred return type is
      // `dynamic`, we use the context.
      // TODO(paulberry): this is inherited from analyzer; it's not part of the
      // spec.
      inferredReturnType = greatestClosure(inferrer.coreTypes, returnContext);
    }

    return _wrapAsyncOrGenerator(inferrer, inferredReturnType);
  }

  void _updateInferredReturnType(TypeInferrerImpl inferrer, DartType type) {
    if (_inferredReturnType == null) {
      _inferredReturnType = type;
    } else {
      _inferredReturnType = inferrer.typeSchemaEnvironment
          .getLeastUpperBound(_inferredReturnType, type);
    }
  }

  DartType _wrapAsyncOrGenerator(TypeInferrerImpl inferrer, DartType type) {
    if (isGenerator) {
      if (isAsync) {
        return inferrer.wrapType(type, inferrer.coreTypes.streamClass);
      } else {
        return inferrer.wrapType(type, inferrer.coreTypes.iterableClass);
      }
    } else if (isAsync) {
      return inferrer.wrapFutureType(type);
    } else {
      return type;
    }
  }

  static bool _analyzerSubtypeOf(
      TypeInferrerImpl inferrer, DartType subtype, DartType supertype) {
    if (supertype is VoidType) {
      if (subtype is VoidType) return true;
      if (subtype is InterfaceType &&
          identical(subtype.classNode, inferrer.coreTypes.nullClass)) {
        return true;
      }
      return false;
    }
    return inferrer.typeSchemaEnvironment.isSubtypeOf(subtype, supertype);
  }
}

/// Enum denoting the kinds of contravariance check that might need to be
/// inserted for a method call.
enum MethodContravarianceCheckKind {
  /// No contravariance check is needed.
  none,

  /// The return value from the method call needs to be checked.
  checkMethodReturn,

  /// The method call needs to be desugared into a getter call, followed by an
  /// "as" check, followed by an invocation of the resulting function object.
  checkGetterReturn,
}

/// Keeps track of the local state for the type inference that occurs during
/// compilation of a single method body or top level initializer.
///
/// This class describes the interface for use by clients of type inference
/// (e.g. BodyBuilder).  Derived classes should derive from [TypeInferrerImpl].
abstract class TypeInferrer {
  /// Gets the [TypePromoter] that can be used to perform type promotion within
  /// this method body or initializer.
  TypePromoter get typePromoter;

  /// Gets the [TypeSchemaEnvironment] being used for type inference.
  TypeSchemaEnvironment get typeSchemaEnvironment;

  /// The URI of the code for which type inference is currently being
  /// performed--this is used for testing.
  String get uri;

  /// Performs full type inference on the given field initializer.
  void inferFieldInitializer(DartType declaredType, Expression initializer);

  /// Performs type inference on the given function body.
  void inferFunctionBody(
      DartType returnType, AsyncMarker asyncMarker, Statement body);

  /// Performs type inference on the given constructor initializer.
  void inferInitializer(Initializer initializer);

  /// Performs type inference on the given metadata annotations.
  void inferMetadata(List<Expression> annotations);

  /// Performs type inference on the given function parameter initializer
  /// expression.
  void inferParameterInitializer(Expression initializer, DartType declaredType);
}

/// Implementation of [TypeInferrer] which doesn't do any type inference.
///
/// This is intended for profiling, to ensure that type inference and type
/// promotion do not slow down compilation too much.
class TypeInferrerDisabled extends TypeInferrer {
  @override
  final typePromoter = new TypePromoterDisabled();

  @override
  final TypeSchemaEnvironment typeSchemaEnvironment;

  TypeInferrerDisabled(this.typeSchemaEnvironment);

  @override
  String get uri => null;

  @override
  void inferFieldInitializer(DartType declaredType, Expression initializer) {}

  @override
  void inferFunctionBody(
      DartType returnType, AsyncMarker asyncMarker, Statement body) {}

  @override
  void inferInitializer(Initializer initializer) {}

  @override
  void inferMetadata(List<Expression> annotations) {}

  @override
  void inferParameterInitializer(
      Expression initializer, DartType declaredType) {}
}

/// Derived class containing generic implementations of [TypeInferrer].
///
/// This class contains as much of the implementation of type inference as
/// possible without knowing the identity of the type parameters.  It defers to
/// abstract methods for everything else.
abstract class TypeInferrerImpl extends TypeInferrer {
  static final FunctionType _functionReturningDynamic =
      new FunctionType(const [], const DynamicType());

  final TypeInferenceEngineImpl engine;

  @override
  final String uri;

  /// Indicates whether the construct we are currently performing inference for
  /// is outside of a method body, and hence top level type inference rules
  /// should apply.
  final bool isTopLevel;

  final CoreTypes coreTypes;

  final bool strongMode;

  final ClassHierarchy classHierarchy;

  final Instrumentation instrumentation;

  final TypeSchemaEnvironment typeSchemaEnvironment;

  final TypeInferenceListener listener;

  final InterfaceType thisType;

  final SourceLibraryBuilder library;

  /// Context information for the current closure, or `null` if we are not
  /// inside a closure.
  ClosureContext closureContext;

  TypeInferrerImpl(this.engine, this.uri, this.listener, bool topLevel,
      this.thisType, this.library)
      : coreTypes = engine.coreTypes,
        strongMode = engine.strongMode,
        classHierarchy = engine.classHierarchy,
        instrumentation = topLevel ? null : engine.instrumentation,
        typeSchemaEnvironment = engine.typeSchemaEnvironment,
        isTopLevel = topLevel;

  /// Gets the type promoter that should be used to promote types during
  /// inference.
  TypePromoter get typePromoter;

  /// Checks whether [actualType] can be assigned to [expectedType], and inserts
  /// an implicit downcast if appropriate.
  Expression checkAssignability(DartType expectedType, DartType actualType,
      Expression expression, int fileOffset) {
    if (expectedType == null ||
        typeSchemaEnvironment.isSubtypeOf(actualType, expectedType)) {
      // Types are compatible.
      return null;
    } else {
      // Insert an implicit downcast.
      if (strongMode) {
        if (!typeSchemaEnvironment.isSubtypeOf(expectedType, actualType)) {
          // Error: not assignable.
          library.addWarning(
              templateInvalidAssignment.withArguments(actualType, expectedType),
              fileOffset,
              Uri.parse(uri));
        }
        var parent = expression.parent;
        var typeCheck = new AsExpression(expression, expectedType)
          ..isTypeError = true
          ..fileOffset = fileOffset;
        parent.replaceChild(expression, typeCheck);
        return typeCheck;
      } else {
        return null;
      }
    }
  }

  /// Finds a member of [receiverType] called [name], and if it is found,
  /// reports it through instrumentation using [fileOffset].
  ///
  /// For the special case where [receiverType] is a [FunctionType], and the
  /// method name is `call`, the string `call` is returned as a sentinel object.
  Object findInterfaceMember(DartType receiverType, Name name, int fileOffset,
      {bool setter: false, bool silent: false}) {
    // Our non-strong golden files currently don't include interface
    // targets, so we can't store the interface target without causing tests
    // to fail.  TODO(paulberry): fix this.
    if (!strongMode) return null;

    receiverType = resolveTypeParameter(receiverType);

    if (receiverType is FunctionType && name.name == 'call') {
      return 'call';
    }

    Class classNode = receiverType is InterfaceType
        ? receiverType.classNode
        : coreTypes.objectClass;

    var interfaceMember = _getInterfaceMember(classNode, name, setter);
    if (!silent && interfaceMember != null) {
      instrumentation?.record(Uri.parse(uri), fileOffset, 'target',
          new InstrumentationValueForMember(interfaceMember));
    }
    return interfaceMember;
  }

  /// Finds a member of [receiverType] called [name], and if it is found,
  /// reports it through instrumentation and records it in [methodInvocation].
  Object findMethodInvocationMember(
      DartType receiverType, InvocationExpression methodInvocation,
      {bool silent: false}) {
    // TODO(paulberry): could we add getters to InvocationExpression to make
    // these is-checks unnecessary?
    if (methodInvocation is MethodInvocation) {
      var interfaceMember = findInterfaceMember(
          receiverType, methodInvocation.name, methodInvocation.fileOffset,
          silent: silent);
      if (strongMode && interfaceMember is Member) {
        methodInvocation.interfaceTarget = interfaceMember;
      }
      return interfaceMember;
    } else if (methodInvocation is SuperMethodInvocation) {
      var interfaceMember = findInterfaceMember(
          receiverType, methodInvocation.name, methodInvocation.fileOffset,
          silent: silent);
      if (strongMode && interfaceMember is Member) {
        methodInvocation.interfaceTarget = interfaceMember;
      }
      return interfaceMember;
    } else {
      throw unhandled(
          "${methodInvocation.runtimeType}",
          "findMethodInvocationMember",
          methodInvocation.fileOffset,
          Uri.parse(uri));
    }
  }

  /// Finds a member of [receiverType] called [name], and if it is found,
  /// reports it through instrumentation and records it in [propertyGet].
  Object findPropertyGetMember(DartType receiverType, Expression propertyGet,
      {bool silent: false}) {
    // TODO(paulberry): could we add a common base class to PropertyGet and
    // SuperPropertyGet to make these is-checks unnecessary?
    if (propertyGet is PropertyGet) {
      var interfaceMember = findInterfaceMember(
          receiverType, propertyGet.name, propertyGet.fileOffset,
          silent: silent);
      if (strongMode && interfaceMember is Member) {
        propertyGet.interfaceTarget = interfaceMember;
      }
      return interfaceMember;
    } else if (propertyGet is SuperPropertyGet) {
      var interfaceMember = findInterfaceMember(
          receiverType, propertyGet.name, propertyGet.fileOffset,
          silent: silent);
      if (strongMode && interfaceMember is Member) {
        propertyGet.interfaceTarget = interfaceMember;
      }
      return interfaceMember;
    } else {
      return unhandled("${propertyGet.runtimeType}", "findPropertyGetMember",
          propertyGet.fileOffset, Uri.parse(uri));
    }
  }

  /// Finds a member of [receiverType] called [name], and if it is found,
  /// reports it through instrumentation and records it in [propertySet].
  Object findPropertySetMember(DartType receiverType, Expression propertySet,
      {bool silent: false}) {
    if (propertySet is PropertySet) {
      var interfaceMember = findInterfaceMember(
          receiverType, propertySet.name, propertySet.fileOffset,
          setter: true, silent: silent);
      if (strongMode && interfaceMember is Member) {
        propertySet.interfaceTarget = interfaceMember;
      }
      return interfaceMember;
    } else if (propertySet is SuperPropertySet) {
      var interfaceMember = findInterfaceMember(
          receiverType, propertySet.name, propertySet.fileOffset,
          setter: true, silent: silent);
      if (strongMode && interfaceMember is Member) {
        propertySet.interfaceTarget = interfaceMember;
      }
      return interfaceMember;
    } else {
      throw unhandled("${propertySet.runtimeType}", "findPropertySetMember",
          propertySet.fileOffset, Uri.parse(uri));
    }
  }

  FunctionType getCalleeFunctionType(
      Object interfaceMember, DartType receiverType, bool followCall) {
    var type = getCalleeType(interfaceMember, receiverType);
    if (type is FunctionType) {
      return type;
    } else if (followCall && type is InterfaceType) {
      var member = _getInterfaceMember(type.classNode, callName, false);
      var callType = member?.getterType;
      if (callType is FunctionType) {
        return callType;
      }
    }
    return _functionReturningDynamic;
  }

  DartType getCalleeType(Object interfaceMember, DartType receiverType) {
    if (identical(interfaceMember, 'call')) {
      return receiverType;
    } else if (interfaceMember == null) {
      return const DynamicType();
    } else if (interfaceMember is Member) {
      var memberClass = interfaceMember.enclosingClass;
      DartType calleeType;
      if (interfaceMember is Procedure) {
        if (interfaceMember.kind == ProcedureKind.Getter) {
          calleeType = interfaceMember.function.returnType;
        } else {
          calleeType = interfaceMember.function.functionType;
        }
      } else if (interfaceMember is Field) {
        calleeType = interfaceMember.type;
      } else {
        throw unhandled(interfaceMember.runtimeType.toString(), 'getCalleeType',
            null, null);
      }
      if (memberClass.typeParameters.isNotEmpty) {
        receiverType = resolveTypeParameter(receiverType);
        if (receiverType is InterfaceType) {
          var castedType =
              classHierarchy.getTypeAsInstanceOf(receiverType, memberClass);
          calleeType = Substitution
              .fromInterfaceType(castedType)
              .substituteType(calleeType);
        }
      }
      return calleeType;
    } else {
      throw unhandled(
          interfaceMember.runtimeType.toString(), 'getCalleeType', null, null);
    }
  }

  DartType getDerivedTypeArgumentOf(DartType type, Class class_) {
    if (type is InterfaceType) {
      var typeAsInstanceOfClass =
          classHierarchy.getTypeAsInstanceOf(type, class_);
      if (typeAsInstanceOfClass != null) {
        return typeAsInstanceOfClass.typeArguments[0];
      }
    }
    return null;
  }

  /// Gets the initializer for the given [field], or `null` if there is no
  /// initializer.
  Expression getFieldInitializer(ShadowField field);

  DartType getSetterType(Object interfaceMember, DartType receiverType) {
    if (interfaceMember is FunctionType) {
      return interfaceMember;
    } else if (interfaceMember == null) {
      return const DynamicType();
    } else if (interfaceMember is Member) {
      var memberClass = interfaceMember.enclosingClass;
      DartType setterType;
      if (interfaceMember is Procedure) {
        assert(interfaceMember.kind == ProcedureKind.Setter);
        var setterParameters = interfaceMember.function.positionalParameters;
        setterType = setterParameters.length > 0
            ? setterParameters[0].type
            : const DynamicType();
      } else if (interfaceMember is Field) {
        setterType = interfaceMember.type;
      } else {
        throw unhandled(interfaceMember.runtimeType.toString(), 'getSetterType',
            null, null);
      }
      if (memberClass.typeParameters.isNotEmpty) {
        receiverType = resolveTypeParameter(receiverType);
        if (receiverType is InterfaceType) {
          var castedType =
              classHierarchy.getTypeAsInstanceOf(receiverType, memberClass);
          setterType = Substitution
              .fromInterfaceType(castedType)
              .substituteType(setterType);
        }
      }
      return setterType;
    } else {
      throw unhandled(
          interfaceMember.runtimeType.toString(), 'getSetterType', null, null);
    }
  }

  DartType getTypeArgumentOf(DartType type, Class class_) {
    if (type is InterfaceType && identical(type.classNode, class_)) {
      return type.typeArguments[0];
    } else {
      return null;
    }
  }

  /// Adds an "as" check to a [MethodInvocation] if necessary due to
  /// contravariance.
  ///
  /// The returned expression is the [AsExpression], if one was added; otherwise
  /// it is the [MethodInvocation].
  Expression handleInvocationContravariance(
      MethodContravarianceCheckKind checkKind,
      MethodInvocation desugaredInvocation,
      Arguments arguments,
      Expression expression,
      DartType inferredType,
      FunctionType functionType,
      int fileOffset) {
    var expressionToReplace = desugaredInvocation ?? expression;
    switch (checkKind) {
      case MethodContravarianceCheckKind.checkMethodReturn:
        var parent = expressionToReplace.parent;
        var replacement = new AsExpression(expressionToReplace, inferredType)
          ..isTypeError = true
          ..fileOffset = fileOffset;
        parent.replaceChild(expressionToReplace, replacement);
        if (instrumentation != null) {
          int offset = arguments.fileOffset == -1
              ? expression.fileOffset
              : arguments.fileOffset;
          instrumentation.record(Uri.parse(uri), offset, 'checkReturn',
              new InstrumentationValueForType(inferredType));
        }
        return replacement;
      case MethodContravarianceCheckKind.checkGetterReturn:
        var parent = expressionToReplace.parent;
        var propertyGet = new PropertyGet(desugaredInvocation.receiver,
            desugaredInvocation.name, desugaredInvocation.interfaceTarget);
        var asExpression = new AsExpression(propertyGet, functionType)
          ..isTypeError = true
          ..fileOffset = fileOffset;
        var replacement = new MethodInvocation(
            asExpression, callName, desugaredInvocation.arguments);
        parent.replaceChild(expressionToReplace, replacement);
        if (instrumentation != null) {
          int offset = arguments.fileOffset == -1
              ? expression.fileOffset
              : arguments.fileOffset;
          instrumentation.record(Uri.parse(uri), offset, 'checkGetterReturn',
              new InstrumentationValueForType(functionType));
        }
        return replacement;
      case MethodContravarianceCheckKind.none:
        break;
    }
    return expressionToReplace;
  }

  /// Determines the dispatch category of a [PropertyGet] and adds an "as" check
  /// if necessary due to contravariance.
  void handlePropertyGetContravariance(
      Expression receiver,
      Object interfaceMember,
      PropertyGet desugaredGet,
      Expression expression,
      DartType inferredType,
      int fileOffset) {
    DispatchCategory callKind;
    if (receiver is ThisExpression) {
      callKind = DispatchCategory.viaThis;
    } else if (interfaceMember == null) {
      callKind = DispatchCategory.dynamicDispatch;
    } else {
      callKind = DispatchCategory.interface;
    }
    desugaredGet?.dispatchCategory = callKind;
    bool checkReturn = false;
    if (callKind == DispatchCategory.interface &&
        interfaceMember is Procedure) {
      checkReturn = interfaceMember.isGenericContravariant;
    }
    if (checkReturn) {
      var expressionToReplace = desugaredGet ?? expression;
      expressionToReplace.parent.replaceChild(
          expressionToReplace,
          new AsExpression(expressionToReplace, inferredType)
            ..isTypeError = true
            ..fileOffset = fileOffset);
    }
    if (instrumentation != null) {
      int offset = expression.fileOffset;
      switch (callKind) {
        case DispatchCategory.dynamicDispatch:
          instrumentation.record(Uri.parse(uri), offset, 'callKind',
              new InstrumentationValueLiteral('dynamic'));
          break;
        case DispatchCategory.viaThis:
          instrumentation.record(Uri.parse(uri), offset, 'callKind',
              new InstrumentationValueLiteral('this'));
          break;
        default:
          break;
      }
      if (checkReturn) {
        instrumentation.record(Uri.parse(uri), offset, 'checkReturn',
            new InstrumentationValueForType(inferredType));
      }
    }
  }

  /// Modifies a type as appropriate when inferring a declared variable's type.
  DartType inferDeclarationType(DartType initializerType) {
    if (initializerType is BottomType ||
        (initializerType is InterfaceType &&
            initializerType.classNode == coreTypes.nullClass)) {
      // If the initializer type is Null or bottom, the inferred type is
      // dynamic.
      // TODO(paulberry): this rule is inherited from analyzer behavior but is
      // not spec'ed anywhere.
      return const DynamicType();
    }
    return initializerType;
  }

  /// Performs type inference on the given [expression].
  ///
  /// [typeContext] is the expected type of the expression, based on surrounding
  /// code.  [typeNeeded] indicates whether it is necessary to compute the
  /// actual type of the expression.  If [typeNeeded] is `true`, the actual type
  /// of the expression is returned; otherwise `null` is returned.
  ///
  /// Derived classes should override this method with logic that dispatches on
  /// the expression type and calls the appropriate specialized "infer" method.
  DartType inferExpression(
      Expression expression, DartType typeContext, bool typeNeeded);

  @override
  void inferFieldInitializer(DartType declaredType, Expression initializer) {
    assert(closureContext == null);
    inferExpression(initializer, declaredType, false);
  }

  /// Performs type inference on the given [field]'s initializer expression.
  ///
  /// Derived classes should provide an implementation that calls
  /// [inferExpression] for the given [field]'s initializer expression.
  DartType inferFieldTopLevel(
      ShadowField field, DartType type, bool typeNeeded);

  @override
  void inferFunctionBody(
      DartType returnType, AsyncMarker asyncMarker, Statement body) {
    assert(closureContext == null);
    closureContext = new ClosureContext(this, asyncMarker, returnType);
    inferStatement(body);
    closureContext = null;
  }

  /// Performs the type inference steps that are shared by all kinds of
  /// invocations (constructors, instance methods, and static methods).
  DartType inferInvocation(DartType typeContext, bool typeNeeded, int offset,
      FunctionType calleeType, DartType returnType, Arguments arguments,
      {bool isOverloadedArithmeticOperator: false,
      DartType receiverType,
      bool skipTypeArgumentInference: false,
      bool isConst: false}) {
    var calleeTypeParameters = calleeType.typeParameters;
    List<DartType> explicitTypeArguments = getExplicitTypeArguments(arguments);
    bool inferenceNeeded = !skipTypeArgumentInference &&
        explicitTypeArguments == null &&
        strongMode &&
        calleeTypeParameters.isNotEmpty;
    List<DartType> inferredTypes;
    Substitution substitution;
    List<DartType> formalTypes;
    List<DartType> actualTypes;
    if (inferenceNeeded) {
      if (isConst && typeContext != null) {
        typeContext =
            new TypeVariableEliminator(coreTypes).substituteType(typeContext);
      }
      inferredTypes = new List<DartType>.filled(
          calleeTypeParameters.length, const UnknownType());
      typeSchemaEnvironment.inferGenericFunctionOrType(returnType,
          calleeTypeParameters, null, null, typeContext, inferredTypes);
      substitution =
          Substitution.fromPairs(calleeTypeParameters, inferredTypes);
      formalTypes = [];
      actualTypes = [];
    } else if (explicitTypeArguments != null &&
        calleeTypeParameters.length == explicitTypeArguments.length) {
      substitution =
          Substitution.fromPairs(calleeTypeParameters, explicitTypeArguments);
    } else if (calleeTypeParameters.length != 0) {
      substitution = Substitution.fromPairs(
          calleeTypeParameters,
          new List<DartType>.filled(
              calleeTypeParameters.length, const DynamicType()));
    }
    // TODO(paulberry): if we are doing top level inference and type arguments
    // were omitted, report an error.
    int i = 0;
    _forEachArgument(arguments, (name, expression) {
      DartType formalType = name != null
          ? getNamedParameterType(calleeType, name)
          : getPositionalParameterType(calleeType, i++);
      DartType inferredFormalType = substitution != null
          ? substitution.substituteType(formalType)
          : formalType;
      var expressionType = inferExpression(expression, inferredFormalType,
          inferenceNeeded || isOverloadedArithmeticOperator);
      if (inferenceNeeded) {
        formalTypes.add(formalType);
        actualTypes.add(expressionType);
      }
      if (isOverloadedArithmeticOperator) {
        returnType = typeSchemaEnvironment.getTypeOfOverloadedArithmetic(
            receiverType, expressionType);
      }
    });
    if (inferenceNeeded) {
      typeSchemaEnvironment.inferGenericFunctionOrType(
          returnType,
          calleeTypeParameters,
          formalTypes,
          actualTypes,
          typeContext,
          inferredTypes);
      substitution =
          Substitution.fromPairs(calleeTypeParameters, inferredTypes);
      instrumentation?.record(Uri.parse(uri), offset, 'typeArgs',
          new InstrumentationValueForTypeArgs(inferredTypes));
      arguments.types.clear();
      arguments.types.addAll(inferredTypes);
    }
    DartType inferredType;
    if (typeNeeded) {
      inferredType = substitution == null
          ? returnType
          : substitution.substituteType(returnType);
    }
    return inferredType;
  }

  DartType inferLocalFunction(FunctionNode function, DartType typeContext,
      bool typeNeeded, int fileOffset, DartType returnContext) {
    bool hasImplicitReturnType = returnContext == null;
    if (!isTopLevel) {
      for (var parameter in function.positionalParameters) {
        if (parameter.initializer != null) {
          inferExpression(parameter.initializer, parameter.type, false);
        }
      }
      for (var parameter in function.namedParameters) {
        if (parameter.initializer != null) {
          inferExpression(parameter.initializer, parameter.type, false);
        }
      }
    }

    // Let `<T0, ..., Tn>` be the set of type parameters of the closure (with
    // `n`=0 if there are no type parameters).
    List<TypeParameter> typeParameters = function.typeParameters;

    // Let `(P0 x0, ..., Pm xm)` be the set of formal parameters of the closure
    // (including required, positional optional, and named optional parameters).
    // If any type `Pi` is missing, denote it as `_`.
    List<VariableDeclaration> formals = function.positionalParameters.toList()
      ..addAll(function.namedParameters);

    // Let `B` denote the closure body.  If `B` is an expression function body
    // (`=> e`), treat it as equivalent to a block function body containing a
    // single `return` statement (`{ return e; }`).

    // Attempt to match `K` as a function type compatible with the closure (that
    // is, one having n type parameters and a compatible set of formal
    // parameters).  If there is a successful match, let `<S0, ..., Sn>` be the
    // set of matched type parameters and `(Q0, ..., Qm)` be the set of matched
    // formal parameter types, and let `N` be the return type.
    Substitution substitution;
    List<DartType> formalTypesFromContext =
        new List<DartType>.filled(formals.length, null);
    if (strongMode && typeContext is FunctionType) {
      for (int i = 0; i < formals.length; i++) {
        if (i < function.positionalParameters.length) {
          formalTypesFromContext[i] =
              getPositionalParameterType(typeContext, i);
        } else {
          formalTypesFromContext[i] =
              getNamedParameterType(typeContext, formals[i].name);
        }
      }
      returnContext = typeContext.returnType;

      // Let `[T/S]` denote the type substitution where each `Si` is replaced
      // with the corresponding `Ti`.
      var substitutionMap = <TypeParameter, DartType>{};
      for (int i = 0; i < typeContext.typeParameters.length; i++) {
        substitutionMap[typeContext.typeParameters[i]] =
            i < typeParameters.length
                ? new TypeParameterType(typeParameters[i])
                : const DynamicType();
      }
      substitution = Substitution.fromMap(substitutionMap);
    } else {
      // If the match is not successful because  `K` is `_`, let all `Si`, all
      // `Qi`, and `N` all be `_`.

      // If the match is not successful for any other reason, this will result
      // in a type error, so the implementation is free to choose the best
      // error recovery path.
      substitution = Substitution.empty;
    }

    // Define `Ri` as follows: if `Pi` is not `_`, let `Ri` be `Pi`.
    // Otherwise, if `Qi` is not `_`, let `Ri` be the greatest closure of
    // `Qi[T/S]` with respect to `?`.  Otherwise, let `Ri` be `dynamic`.
    for (int i = 0; i < formals.length; i++) {
      ShadowVariableDeclaration formal = formals[i];
      if (ShadowVariableDeclaration.isImplicitlyTyped(formal)) {
        DartType inferredType;
        if (formalTypesFromContext[i] != null) {
          inferredType = greatestClosure(coreTypes,
              substitution.substituteType(formalTypesFromContext[i]));
        } else {
          inferredType = const DynamicType();
        }
        instrumentation?.record(Uri.parse(uri), formal.fileOffset, 'type',
            new InstrumentationValueForType(inferredType));
        formal.type = inferredType;
      }
    }

    // Let `N'` be `N[T/S]`.  The [ClosureContext] constructor will adjust
    // accordingly if the closure is declared with `async`, `async*`, or
    // `sync*`.
    if (returnContext != null) {
      returnContext = substitution.substituteType(returnContext);
    }

    // Apply type inference to `B` in return context `N’`, with any references
    // to `xi` in `B` having type `Pi`.  This produces `B’`.
    bool isExpressionFunction = function.body is ReturnStatement;
    bool needToSetReturnType = hasImplicitReturnType && strongMode;
    ClosureContext oldClosureContext = this.closureContext;
    ClosureContext closureContext =
        new ClosureContext(this, function.asyncMarker, returnContext);
    this.closureContext = closureContext;
    inferStatement(function.body);

    // If the closure is declared with `async*` or `sync*`, let `M` be the
    // least upper bound of the types of the `yield` expressions in `B’`, or
    // `void` if `B’` contains no `yield` expressions.  Otherwise, let `M` be
    // the least upper bound of the types of the `return` expressions in `B’`,
    // or `void` if `B’` contains no `return` expressions.
    DartType inferredReturnType;
    if (needToSetReturnType || typeNeeded) {
      inferredReturnType =
          closureContext.inferReturnType(this, isExpressionFunction);
    }

    // Then the result of inference is `<T0, ..., Tn>(R0 x0, ..., Rn xn) B` with
    // type `<T0, ..., Tn>(R0, ..., Rn) -> M’` (with some of the `Ri` and `xi`
    // denoted as optional or named parameters, if appropriate).
    if (needToSetReturnType) {
      instrumentation?.record(Uri.parse(uri), fileOffset, 'returnType',
          new InstrumentationValueForType(inferredReturnType));
      function.returnType = inferredReturnType;
    } else if (!strongMode && hasImplicitReturnType) {
      function.returnType =
          closureContext._wrapAsyncOrGenerator(this, const DynamicType());
    }
    this.closureContext = oldClosureContext;
    return typeNeeded ? function.functionType : null;
  }

  @override
  void inferMetadata(List<Expression> annotations) {
    if (annotations != null) {
      for (var annotation in annotations) {
        inferExpression(annotation, null, false);
      }
    }
  }

  /// Performs the core type inference algorithm for method invocations (this
  /// handles both null-aware and non-null-aware method invocations).
  DartType inferMethodInvocation(
      Expression expression,
      Expression receiver,
      int fileOffset,
      bool isImplicitCall,
      DartType typeContext,
      bool typeNeeded,
      {VariableDeclaration receiverVariable,
      MethodInvocation desugaredInvocation,
      Object interfaceMember,
      Name methodName,
      Arguments arguments}) {
    typeNeeded =
        listener.methodInvocationEnter(expression, typeContext) || typeNeeded;
    // First infer the receiver so we can look up the method that was invoked.
    var receiverType = inferExpression(receiver, null, true);
    listener.methodInvocationBeforeArgs(expression, isImplicitCall);
    if (strongMode) {
      receiverVariable?.type = receiverType;
    }
    bool isOverloadedArithmeticOperator = false;
    if (desugaredInvocation != null) {
      interfaceMember =
          findMethodInvocationMember(receiverType, desugaredInvocation);
      methodName = desugaredInvocation.name;
      arguments = desugaredInvocation.arguments;
    }
    if (interfaceMember is Procedure) {
      isOverloadedArithmeticOperator = typeSchemaEnvironment
          .isOverloadedArithmeticOperatorAndType(interfaceMember, receiverType);
    }
    var calleeType =
        getCalleeFunctionType(interfaceMember, receiverType, !isImplicitCall);
    var checkKind = preCheckInvocationContravariance(receiver, receiverType,
        interfaceMember, desugaredInvocation, arguments, expression);
    var inferredType = inferInvocation(
        typeContext,
        typeNeeded || checkKind != MethodContravarianceCheckKind.none,
        fileOffset,
        calleeType,
        calleeType.returnType,
        arguments,
        isOverloadedArithmeticOperator: isOverloadedArithmeticOperator,
        receiverType: receiverType);
    handleInvocationContravariance(checkKind, desugaredInvocation, arguments,
        expression, inferredType, calleeType, fileOffset);
    listener.methodInvocationExit(
        expression, arguments, isImplicitCall, inferredType);
    return inferredType;
  }

  @override
  void inferParameterInitializer(
      Expression initializer, DartType declaredType) {
    assert(closureContext == null);
    inferExpression(initializer, declaredType, false);
  }

  /// Performs the core type inference algorithm for property gets (this handles
  /// both null-aware and non-null-aware property gets).
  DartType inferPropertyGet(Expression expression, Expression receiver,
      int fileOffset, DartType typeContext, bool typeNeeded,
      {VariableDeclaration receiverVariable,
      PropertyGet desugaredGet,
      Name propertyName}) {
    typeNeeded =
        listener.propertyGetEnter(expression, typeContext) || typeNeeded;
    // First infer the receiver so we can look up the getter that was invoked.
    var receiverType = inferExpression(receiver, null, true);
    if (strongMode) {
      receiverVariable?.type = receiverType;
    }
    propertyName ??= desugaredGet.name;
    var interfaceMember =
        findInterfaceMember(receiverType, propertyName, fileOffset);
    if (interfaceMember is Member) {
      desugaredGet?.interfaceTarget = interfaceMember;
    }
    var inferredType = getCalleeType(interfaceMember, receiverType);
    // TODO(paulberry): Infer tear-off type arguments if appropriate.
    handlePropertyGetContravariance(receiver, interfaceMember, desugaredGet,
        expression, inferredType, fileOffset);
    listener.propertyGetExit(expression, inferredType);
    return typeNeeded ? inferredType : null;
  }

  /// Modifies a type as appropriate when inferring a closure return type.
  DartType inferReturnType(DartType returnType, bool isExpressionFunction) {
    if (returnType == null) {
      // Analyzer infers `Null` if there is no `return` expression; the spec
      // says to return `void`.  TODO(paulberry): resolve this difference.
      return coreTypes.nullClass.rawType;
    }
    if (isExpressionFunction &&
        returnType is InterfaceType &&
        identical(returnType.classNode, coreTypes.nullClass)) {
      // Analyzer coerces `Null` to `dynamic` in expression functions; the spec
      // doesn't say to do this.  TODO(paulberry): resolve this difference.
      return const DynamicType();
    }
    return returnType;
  }

  /// Performs type inference on the given [statement].
  ///
  /// Derived classes should override this method with logic that dispatches on
  /// the statement type and calls the appropriate specialized "infer" method.
  void inferStatement(Statement statement);

  /// Determines the dispatch category of a [MethodInvocation] and returns a
  /// boolean indicating whether an "as" check will need to be added due to
  /// contravariance.
  MethodContravarianceCheckKind preCheckInvocationContravariance(
      Expression receiver,
      DartType receiverType,
      Object interfaceMember,
      MethodInvocation desugaredInvocation,
      Arguments arguments,
      Expression expression) {
    DispatchCategory callKind;
    var checkKind = MethodContravarianceCheckKind.none;
    if (interfaceMember is Field ||
        interfaceMember is Procedure &&
            interfaceMember.kind == ProcedureKind.Getter) {
      var getType = getCalleeType(interfaceMember, receiverType);
      if (getType is DynamicType) {
        callKind = DispatchCategory.dynamicDispatch;
      } else {
        callKind = DispatchCategory.closure;
        if (receiver is! ThisExpression) {
          if (interfaceMember is Field &&
              interfaceMember.isGenericContravariant) {
            checkKind = MethodContravarianceCheckKind.checkGetterReturn;
          } else if (interfaceMember is Procedure &&
              interfaceMember.isGenericContravariant) {
            checkKind = MethodContravarianceCheckKind.checkGetterReturn;
          }
        }
      }
    } else if (receiver is ThisExpression) {
      callKind = DispatchCategory.viaThis;
    } else if (identical(interfaceMember, 'call')) {
      callKind = DispatchCategory.closure;
    } else if (interfaceMember == null) {
      callKind = DispatchCategory.dynamicDispatch;
    } else {
      callKind = DispatchCategory.interface;
      if (interfaceMember is Procedure &&
          interfaceMember.isGenericContravariant) {
        checkKind = MethodContravarianceCheckKind.checkMethodReturn;
      }
    }
    desugaredInvocation?.dispatchCategory = callKind;
    if (instrumentation != null) {
      int offset = arguments.fileOffset == -1
          ? expression.fileOffset
          : arguments.fileOffset;
      switch (callKind) {
        case DispatchCategory.closure:
          instrumentation.record(Uri.parse(uri), offset, 'callKind',
              new InstrumentationValueLiteral('closure'));
          break;
        case DispatchCategory.dynamicDispatch:
          instrumentation.record(Uri.parse(uri), offset, 'callKind',
              new InstrumentationValueLiteral('dynamic'));
          break;
        case DispatchCategory.viaThis:
          instrumentation.record(Uri.parse(uri), offset, 'callKind',
              new InstrumentationValueLiteral('this'));
          break;
        default:
          break;
      }
    }
    return checkKind;
  }

  /// If the given [type] is a [TypeParameterType], resolve it to its bound.
  DartType resolveTypeParameter(DartType type) {
    DartType resolveOneStep(DartType type) {
      if (type is TypeParameterType) {
        return type.bound;
      } else {
        return null;
      }
    }

    var resolved = resolveOneStep(type);
    if (resolved == null) return type;

    // Detect circularities using the tortoise-and-hare algorithm.
    type = resolved;
    DartType hare = resolveOneStep(type);
    if (hare == null) return type;
    while (true) {
      if (identical(type, hare)) {
        // We found a circularity.  Give up and return `dynamic`.
        return const DynamicType();
      }

      // Hare takes two steps
      var step1 = resolveOneStep(hare);
      if (step1 == null) return hare;
      var step2 = resolveOneStep(step1);
      if (step2 == null) return hare;
      hare = step2;

      // Tortoise takes one step
      type = resolveOneStep(type);
    }
  }

  DartType wrapFutureOrType(DartType type) {
    if (type is InterfaceType &&
        identical(type.classNode, coreTypes.futureOrClass)) {
      return type;
    }
    // TODO(paulberry): If [type] is a subtype of `Future`, should we just
    // return it unmodified?
    return new InterfaceType(
        coreTypes.futureOrClass, <DartType>[type ?? const DynamicType()]);
  }

  DartType wrapFutureType(DartType type) {
    var typeWithoutFutureOr = type ?? const DynamicType();
    if (type is InterfaceType &&
        identical(type.classNode, coreTypes.futureOrClass)) {
      typeWithoutFutureOr = type.typeArguments[0];
    }
    return new InterfaceType(coreTypes.futureClass,
        <DartType>[typeSchemaEnvironment.flattenFutures(typeWithoutFutureOr)]);
  }

  DartType wrapType(DartType type, Class class_) {
    return new InterfaceType(class_, <DartType>[type ?? const DynamicType()]);
  }

  void _forEachArgument(
      Arguments arguments, void callback(String name, Expression expression)) {
    for (var expression in arguments.positional) {
      callback(null, expression);
    }
    for (var namedExpression in arguments.named) {
      callback(namedExpression.name, namedExpression.value);
    }
  }

  Member _getInterfaceMember(Class class_, Name name, bool setter) {
    if (class_ is ShadowClass) {
      var classInferenceInfo = ShadowClass.getClassInferenceInfo(class_);
      if (classInferenceInfo != null) {
        var member = ClassHierarchy.findMemberByName(
            setter
                ? classInferenceInfo.setters
                : classInferenceInfo.gettersAndMethods,
            name);
        if (member == null) return null;
        member = member is ForwardingNode ? member.resolve() : member;
        member = member is SyntheticAccessor
            ? SyntheticAccessor.getField(member)
            : member;
        ShadowMember.resolveInferenceNode(member);
        return member;
      }
    }
    return classHierarchy.getInterfaceMember(class_, name, setter: setter);
  }
}
