{-# LANGUAGE TupleSections #-}

module Crux.Typecheck.Env
    ( newEnv
    , childEnv
    , buildTypeEnvironment
    , registerTypeVarIdent
    , registerExplicitTypeVariables
    , newQuantifiedTypeVar
    , newQuantifiedConstrainedTypeVar
    , resolveTypeIdent
    , exportedDecls

    , resolveValueReference
    , resolveTypeReference
    , resolveBooleanType
    , resolveStringType
    , resolveArrayType
    , resolveNumberType
    , resolveVoidType
    , resolvePatternReference
    , resolveTraitReference
    , resolveExceptionReference
    ) where

import Crux.AST
import Crux.ModuleName
import qualified Crux.Error as Error
import Crux.Module.Types
import Crux.Prelude
import Crux.Typecheck.Monad
import Crux.Typecheck.Types
import Crux.Typecheck.Unify
import Crux.TypeVar
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text as Text
import Prelude hiding (String)
import qualified Crux.SymbolTable as SymbolTable
import qualified Crux.HashTable as HashTable
import qualified Data.Set as Set

newEnv :: MonadIO m => ModuleName -> HashMap ModuleName LoadedModule -> Maybe TypeVar -> m Env
newEnv eThisModule eLoadedModules eReturnType = do
    eNextTypeIndex <- newIORef 0
    eValueBindings <- SymbolTable.new
    eTypeBindings <- SymbolTable.new
    ePatternBindings <- SymbolTable.new
    eTraitBindings <- SymbolTable.new
    eExceptionBindings <- SymbolTable.new
    eExportedValues <- SymbolTable.new
    eExportedTypes <- SymbolTable.new
    eExportedPatterns <- SymbolTable.new
    eExportedTraits <- SymbolTable.new
    eExportedExceptions <- SymbolTable.new
    eKnownInstances <- HashTable.new
    return Env
        { eInLoop = False
        , eLevel = 1
        , ..
        }

childEnv :: MonadIO m => Env -> m Env
childEnv env@Env{..} = do
    valueBindings <- SymbolTable.clone eValueBindings
    typeBindings <- SymbolTable.clone eTypeBindings
    patternBindings <- SymbolTable.clone ePatternBindings
    exceptionBindings <- SymbolTable.clone eExceptionBindings
    return env
        { eValueBindings = valueBindings
        , eTypeBindings = typeBindings
        , ePatternBindings = patternBindings
        , eExceptionBindings = exceptionBindings
        , eLevel = eLevel + 1
        }

exportedDecls :: [Declaration a b c] -> [DeclarationType a b c]
exportedDecls decls = [dt | (Declaration Export _ dt) <- decls]

resolveTypeIdent :: Env -> Pos -> TypeIdent -> TC TypeVar
resolveTypeIdent env@Env{..} pos typeIdent =
    go typeIdent
  where
    go :: TypeIdent -> TC TypeVar
    go UnitTypeIdent = do
        resolveVoidType env pos

    go (TypeIdent typeName typeParameters) = do
        ty <- resolveTypeReference env pos typeName >>= followTypeVar
        case ty of
            TDataType TDataTypeDef{tuName}
                | [] == typeParameters -> do
                    return ty
                | otherwise -> do
                    failTypeError pos $ Error.IllegalTypeApplication tuName
            TTypeFun tuParameters _rt
                | [] == typeParameters -> do
                    return ty
                | length tuParameters == length typeParameters -> do
                    (TTypeFun tuParameters' rt') <- instantiate env ty
                    for_ (zip tuParameters' typeParameters) $ \(a, b) -> do
                        b' <- resolveTypeIdent env pos b
                        unify env pos a b'
                    return rt'
                | otherwise -> do
                    failTypeError pos $ Error.TypeApplicationMismatch (getUnresolvedReferenceLeaf typeName) (length tuParameters) (length typeParameters)
            _
                | [] == typeParameters ->
                    return ty
                | otherwise ->
                    failTypeError pos $ Error.IllegalTypeApplication (Text.pack $ show ty)

    go (RecordIdent rows) = do
        rows' <- for rows $ \(trName, mut, rowTypeIdent) -> do
            let trMut = case mut of
                    Nothing -> RFree
                    Just Mutable -> RMutable
                    Just Immutable -> RImmutable
            trTyVar <- go rowTypeIdent
            return TypeRow{..}
        ref <- newIORef $ RRecord $ RecordType RecordClose rows'
        return $ TRecord $ ref

    go (FunctionIdent argTypes retPrimitive) = do
        argTypes' <- for argTypes go
        retPrimitive' <- go retPrimitive
        return $ TFun argTypes' retPrimitive'

    go (ArrayIdent mutability elementType) = do
        elementType' <- go elementType
        (arrayType, elementType'') <- resolveArrayType env pos mutability
        unify env pos elementType' elementType''
        return arrayType

    go (OptionIdent elementType) = do
        elementType' <- go elementType
        (optionType, elementType'') <- resolveOptionType env pos
        unify env pos elementType' elementType''
        return optionType

registerTypeVarIdent :: Env -> TypeVarIdent -> TC TypeVar
registerTypeVarIdent env (TypeVarIdent name pos traits) = do
    traitIdentities <- for traits $ \traitName -> do
        (_, traitIdentity, _) <- resolveTraitReference env pos traitName
        return traitIdentity
    -- TODO: eliminate duplicates? at least warn
    tyVar <- freshTypeConstrained env $ Set.fromList traitIdentities
    quantify tyVar

    SymbolTable.insert (eTypeBindings env) pos SymbolTable.DisallowDuplicates name tyVar
    return tyVar

registerExplicitTypeVariables :: Env -> [TypeVarIdent] -> TC [TypeVar]
registerExplicitTypeVariables env forall = do
    for forall $ registerTypeVarIdent env
    
newQuantifiedTypeVar :: Env -> Pos -> Name -> TC TypeVar
newQuantifiedTypeVar env pos name = do
    tyVar <- freshType env
    quantify tyVar

    SymbolTable.insert (eTypeBindings env) pos SymbolTable.DisallowDuplicates name tyVar
    return tyVar

newQuantifiedConstrainedTypeVar :: Env -> Pos -> Name -> TraitIdentity -> TC TypeVar
newQuantifiedConstrainedTypeVar env pos name traitIdentity = do
    tyVar <- freshTypeConstrained env $ Set.singleton traitIdentity
    quantify tyVar

    SymbolTable.insert (eTypeBindings env) pos SymbolTable.DisallowDuplicates name tyVar
    return tyVar

-- TODO: what do we do with this when Variants know their own types
createUserTypeDef :: Env
                  -> Name
                  -> ModuleName
                  -> [TypeVar]
                  -> [Variant _edata]
                  -> TC (TDataTypeDef TypeVar)
createUserTypeDef env name moduleName typeVars variants = do
    variants' <- for variants $ \(Variant _typeVar vname vparameters) -> do
        -- the variant parameters are unified with the corresponding typeidents later
        tvParameters <- for vparameters $ const $ freshType env
        let tvName = vname
        return TVariant {..}

    return $ TDataTypeDef
        { tuName = name
        , tuModuleName = moduleName
        , tuParameters = typeVars
        , tuVariants = variants'
        }

buildTypeEnvironment :: ModuleName -> HashMap ModuleName LoadedModule -> Module UnresolvedReference () Pos -> TC Env
buildTypeEnvironment thisModuleName loadedModules thisModule = do
    let imports = mImports thisModule

    -- built-in types. would be nice to move into the prelude somehow.
    env <- newEnv thisModuleName loadedModules Nothing

    -- Phase 1
    for_ imports $ \case
        (pos, UnqualifiedImport importName) -> do
            importedModule <- case HashMap.lookup importName loadedModules of
                Just im -> return im
                Nothing -> failICE $ Error.DependentModuleNotLoaded pos importName

            for_ (Set.toList $ lmKnownInstances importedModule) $ \(a, b, c) -> do
                HashTable.insert (a, b) c $ eKnownInstances env

            -- populate types
            for_ (lmExportedTypes importedModule) $ \(name, typeVar) -> do
                SymbolTable.insert (eTypeBindings env) pos SymbolTable.DisallowDuplicates name typeVar

            -- populate values
            for_ (lmExportedValues importedModule) $ \(name, (resolvedReference, mutability, tr)) -> do
                SymbolTable.insert (eValueBindings env) pos SymbolTable.DisallowDuplicates name (ValueReference resolvedReference mutability tr)

            -- populate patterns
            for_ (lmExportedPatterns importedModule) $ \(name, pb) -> do
                SymbolTable.insert (ePatternBindings env) pos SymbolTable.DisallowDuplicates name pb

        (pos, QualifiedImport moduleName importName) -> do
            importedModule <- case HashMap.lookup moduleName loadedModules of
                Just im -> return im
                Nothing -> failICE $ Error.DependentModuleNotLoaded pos moduleName

            for_ (Set.toList $ lmKnownInstances importedModule) $ \(a, b, c) -> do
                HashTable.insert (a, b) c $ eKnownInstances env

            for_ importName $ \importName' -> do
                SymbolTable.insert (eValueBindings env) pos SymbolTable.DisallowDuplicates importName' (ModuleReference moduleName)

    addThisModuleDataDeclsToEnvironment env thisModule

    return env

-- Phase 2a
registerJSFFIDecl :: Env -> DeclarationType UnresolvedReference () Pos -> TC ()
registerJSFFIDecl env = \case
    DExportImport {} -> return ()

    DDeclare {} -> return ()
    DLet {} -> return ()
    DFun {} -> return ()

    DData {} -> return ()
    DJSData pos name variants -> do
        -- jsffi data never has type parameters, so we can just blast through the whole thing in one pass
        variants' <- for variants $ \(JSVariant variantName _value) -> do
            let tvParameters = []
            let tvName = variantName
            return TVariant{..}

        let typeDef = TDataTypeDef
                { tuName = name
                , tuModuleName = eThisModule env
                , tuParameters = []
                , tuVariants = variants'
                }
        let userType = TDataType typeDef
        SymbolTable.insert (eTypeBindings env) pos SymbolTable.DisallowDuplicates name userType

        for_ variants $ \(JSVariant variantName value) -> do
            SymbolTable.insert (eValueBindings env) pos SymbolTable.DisallowDuplicates variantName (ValueReference (Local, variantName) Immutable userType)
            SymbolTable.insert (ePatternBindings env) pos SymbolTable.DisallowDuplicates variantName (PatternReference typeDef $ TagLiteral value)
        return ()
    DTypeAlias {} -> return ()

    DTrait {} -> return ()
    DImpl {} -> return ()

    DException {} -> return ()

registerExceptionDecl :: Env -> DeclarationType UnresolvedReference () Pos -> TC ()
registerExceptionDecl env = \case
    DExportImport {} -> return ()

    DDeclare {} -> return ()
    DLet {} -> return ()
    DFun {} -> return ()

    DData {} -> return ()
    DJSData {} -> return ()
    DTypeAlias {} -> return ()

    DTrait {} -> return ()
    DImpl {} -> return ()

    DException pos exceptionName typeIdent -> do
        tyVar <- resolveTypeIdent env pos typeIdent
        SymbolTable.insert (eExceptionBindings env) pos SymbolTable.DisallowDuplicates exceptionName ((FromModule $ eThisModule env, exceptionName), tyVar)
        return ()

addThisModuleDataDeclsToEnvironment
    :: Env
    -> Module UnresolvedReference () Pos
    -> TC ()
addThisModuleDataDeclsToEnvironment env thisModule = do
    {-
    populate environment:
        eTypeBindings
        eValueBindings
        ePatternBindings

    phase 1:
        register all qualified imports
        register all unqualified imports

    phase 2:
        a. register all jsffi types (both data constructors and patterns)
        b. register all data types (and only the types)
        c. register all type aliases
        d. register traits (but not their bodies)
        e. register all data type constructors and patterns (using same qvars from before)

    phase 3:
        register all exceptions

    phase 4:
        a. register all trait definitions
        b. register all impls
        c. type check all values in order
    -}

    let decls = [decl | Declaration _ _ decl <- mDecls thisModule]

    -- Phase 2a
    for_ decls $ \decl -> do
        registerJSFFIDecl env decl

    -- Phase 2b.
    dataDecls <- fmap catMaybes $ for decls $ \case
        DData pos name typeVarNames variants ->
            return $ Just (pos, name, typeVarNames, variants)
        _ ->
            return Nothing

    dataDecls' <- for dataDecls $ \(pos, typeName, typeVarNames, variants) -> do
        e <- childEnv env
        tyVars <- registerExplicitTypeVariables e typeVarNames

        typeDef <- createUserTypeDef e typeName (eThisModule env) tyVars variants
        let tyVar = TDataType typeDef
        let typeRef = case tyVars of
                [] -> tyVar
                _ -> TTypeFun tyVars tyVar
        SymbolTable.insert (eTypeBindings env) pos SymbolTable.DisallowDuplicates typeName typeRef

        let qvars = zip typeVarNames tyVars
        return (pos, typeDef, tyVar, qvars, variants)

    -- Phase 2c.
    aliasDecls <- fmap catMaybes $ for decls $ \case
        DTypeAlias pos name params ident -> do
            bodyTypeVar <- freshType env

            paramTypes <- for params $ \tvName -> do
                tv <- freshType env
                quantify tv
                return (tvName, tv)

            let registeredType = case params of
                    [] -> bodyTypeVar
                    _ -> TTypeFun (fmap snd paramTypes) bodyTypeVar
            SymbolTable.insert (eTypeBindings env) pos SymbolTable.DisallowDuplicates name registeredType
            return $ Just (pos, paramTypes, ident, bodyTypeVar)
        _ -> do
            return Nothing

    -- Phase 2c.2.
    for_ aliasDecls $ \(pos, paramTypes, ident, bodyTypeVar) -> do
        env' <- childEnv env
        for_ paramTypes $ \(tvName, tv) -> do
            SymbolTable.insert (eTypeBindings env') pos SymbolTable.DisallowDuplicates tvName tv
        resolvedType <- resolveTypeIdent env' pos ident
        unify env pos bodyTypeVar resolvedType

    -- Phase 2d.
    traitDecls <- fmap catMaybes $ for decls $ \case
        DTrait pos name typeVarName defns -> do
            env' <- childEnv env

            let tn = TraitIdentity (eThisModule env) name

            typeVar <- newQuantifiedConstrainedTypeVar env' pos name tn
            SymbolTable.insert (eTypeBindings env') pos SymbolTable.DisallowDuplicates typeVarName typeVar
            methods <- for defns $ \(mname, mpos, typeIdent) -> do
                tv <- resolveTypeIdent env' mpos typeIdent
                return (mname, mpos, tv)

            let desc = TraitDesc
                    { tdName = name
                    , tdModule = eThisModule env
                    , tdTypeVar = typeVar
                    , tdMethods = map (\(a, _, b) -> (a, b)) methods
                    }
            SymbolTable.insert (eTraitBindings env) pos SymbolTable.DisallowDuplicates name ((FromModule (eThisModule env), name), tn, desc)
            return $ Just methods
        _ -> return Nothing

    -- Phase 2e.
    for_ dataDecls' $ \(pos, typeDef, tyVar, qvars, variants) -> do
        e <- childEnv env
        for_ qvars $ \(TypeVarIdent qvName _ _, qvTypeVar) ->
            SymbolTable.insert (eTypeBindings e) pos SymbolTable.DisallowDuplicates qvName qvTypeVar

        for_ (zip variants $ tuVariants typeDef) $ \(Variant vpos _ typeIdents, TVariant _ typeVars) -> do
            for_ (zip typeIdents typeVars) $ \(typeIdent, typeVar) -> do
                tv' <- resolveTypeIdent e vpos typeIdent
                unify env vpos typeVar tv'

        let computeVariantType [] = tyVar
            computeVariantType argTypeIdents = TFun argTypeIdents tyVar

        for_ variants $ \(Variant _typeVar vname vparameters) -> do
            parameterTypeVars <- traverse (resolveTypeIdent e pos) vparameters
            let ctorType = computeVariantType parameterTypeVars
            SymbolTable.insert (eValueBindings env) pos SymbolTable.DisallowDuplicates vname (ValueReference (FromModule $ eThisModule env, vname) Immutable ctorType)
            SymbolTable.insert (ePatternBindings env) pos SymbolTable.DisallowDuplicates vname (PatternReference typeDef $ TagVariant vname)

    -- Phase 3.
    for_ decls $ \decl -> do
        registerExceptionDecl env decl

    -- Phase 4a.
    for_ traitDecls $ \defns -> do
        for_ defns $ \(defName, defPos, defTypeVar) -> do
            SymbolTable.insert (eValueBindings env) defPos SymbolTable.DisallowDuplicates defName $ ValueReference (FromModule $ eThisModule env, defName) Immutable defTypeVar
    
    -- Phase 4b.
    for_ decls $ \case
        DImpl pos traitName forall typeReference _values -> do
            (_, traitNumber, _) <- resolveTraitReference env pos traitName

            -- TODO: we could have a function which reads the type identity from a TypeVar without needing a full typeident resolution
            -- it would just look at the outermost constructor name
            env' <- childEnv env
            for_ forall $ \typeVarIdent -> do
                registerTypeVarIdent env' typeVarIdent
            typeVar <- resolveTypeIdent env' pos typeReference
            typeIdentity <- case typeVar of
                TDataType def -> return $ dataTypeIdentity def
                _ -> fail "Type doesn't support traits"
            
            HashTable.insert (traitNumber, typeIdentity) (eThisModule env) (eKnownInstances env)
        _ -> return ()
