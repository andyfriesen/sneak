{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}

module Crux.Typecheck.Unify where

import Crux.AST
import Crux.Error
import qualified Crux.HashTable as HashTable
import Crux.Prelude
import Crux.Typecheck.Monad
import Crux.Typecheck.Types
import Crux.TypeVar
import Data.List (sort)
import qualified Data.HashMap.Strict as HashMap
import Text.Printf (printf)
import qualified Data.Set as Set
import qualified Crux.SymbolTable as SymbolTable
import Crux.Module.Types
import Crux.Pos (Pos)
import qualified Crux.Error as Error
import Crux.ModuleName (ModuleName)
import Crux.Util
import qualified Data.Text as Text

freshTypeIndex :: MonadIO m => Env -> m Int
freshTypeIndex Env{eNextTypeIndex} = do
    modifyIORef' eNextTypeIndex (+1)
    readIORef eNextTypeIndex

freshType :: MonadIO m => Env -> m TypeVar
freshType env = freshTypeConstrained env emptyConstraintSet

freshTypeConstrained :: MonadIO m => Env -> ConstraintSet -> m TypeVar
freshTypeConstrained env constraints = do
    index <- freshTypeIndex env
    newTypeVar $ TUnbound Strong (eLevel env) constraints index

freshWeakQVar :: MonadIO m => Env -> m TypeVar
freshWeakQVar env = do
    index <- freshTypeIndex env
    newTypeVar $ TUnbound Weak (eLevel env) emptyConstraintSet index

findExportByName :: (LoadedModule -> [(Name, a)]) -> Env -> Pos -> ModuleName -> Name -> TC a
findExportByName getExports env pos moduleName valueName = do
    modul <- case HashMap.lookup moduleName (eLoadedModules env) of
        Just modul -> return modul
        Nothing -> failICE pos $ DependentModuleNotLoaded moduleName
    let r = findFirstOf (getExports modul) $ \(name, v) ->
            if name == valueName then
                Just v
            else
                Nothing
    case r of
        Just e -> return e
        Nothing -> do
            failTypeError pos $ ModuleReferenceError moduleName valueName

resolveImportName :: Env -> Pos -> Name -> TC ModuleName
resolveImportName env pos importName = do
    SymbolTable.lookup (eValueBindings env) importName >>= \case
        Just (ModuleReference moduleName) -> return moduleName
        -- TODO: should we differentiate between these cases?
        Just _ -> failTypeError pos $ Error.UnboundSymbol "import" importName
        _ -> failTypeError pos $ Error.UnboundSymbol "import" importName

-- I could merge this into ResolveReference but that's a bit tricky because of the ModuleReference stuff
resolveValueReference :: Env -> Pos -> UnresolvedReference -> TC (ResolvedReference, Mutability, TypeVar)
resolveValueReference env pos = \case
    UnqualifiedReference name -> do
        SymbolTable.lookup (eValueBindings env) name >>= \case
            Just (ValueReference rr mut t) -> return (rr, mut, t)
            -- TODO: turn this into a custom error message
            Just (ModuleReference _) -> failTypeError pos $ Error.UnboundSymbol "value" name
            Nothing -> failTypeError pos $ Error.UnboundSymbol "value" name
    QualifiedReference importName name -> do
        moduleName <- resolveImportName env pos importName
        resolveValueReference env pos $ KnownReference moduleName name
    KnownReference moduleName name -> do
        if moduleName == eThisModule env then do
            resolveValueReference env pos (UnqualifiedReference name)
        else do
            findExportByName lmExportedValues env pos moduleName name

resolveReference :: [Char] -> (Env -> SymbolTable.SymbolTable a) -> (LoadedModule -> [(Name, a)]) -> Env -> Pos -> UnresolvedReference -> TC a
resolveReference symbolType bindingTable exportTable env pos = \case
    UnqualifiedReference name -> do
        SymbolTable.lookup (bindingTable env) name >>= \case
            Just er -> return er
            Nothing -> failTypeError pos $ Error.UnboundSymbol symbolType name
    QualifiedReference importName name -> do
        moduleName <- resolveImportName env pos importName
        resolveReference symbolType bindingTable exportTable env pos $ KnownReference moduleName name
    KnownReference moduleName name -> do
        if moduleName == eThisModule env then do
            resolveReference symbolType bindingTable exportTable env pos (UnqualifiedReference name)
        else do
            findExportByName exportTable env pos moduleName name

resolveTypeReference :: Env -> Pos -> UnresolvedReference -> TC TypeVar
resolveTypeReference = resolveReference "type" eTypeBindings lmExportedTypes

resolvePatternReference :: Env -> Pos -> UnresolvedReference -> TC PatternReference
resolvePatternReference = resolveReference "pattern" ePatternBindings lmExportedPatterns

resolveTraitReference :: Env -> Pos -> UnresolvedReference -> TC (ResolvedReference, TraitIdentity, TraitDesc)
resolveTraitReference = resolveReference "trait" eTraitBindings lmExportedTraits

resolveExceptionReference :: Env -> Pos -> UnresolvedReference -> TC (ResolvedReference, TypeVar)
resolveExceptionReference = resolveReference "exception" eExceptionBindings lmExportedExceptions

data TypeApplicationPolicy = AllowTypeFunctions | DisallowTypeFunctions
    deriving (Eq)

applyTypeFunction :: Env -> Pos -> UnresolvedReference -> TypeApplicationPolicy -> TypeVar -> [TypeVar] -> TC TypeVar
applyTypeFunction env pos typeReference typeApplicationPolicy inputType typeArguments = do
    let typeName = getUnresolvedReferenceLeaf typeReference
    ty <- followTypeVar inputType
    case ty of
        TDataType TDataTypeDef{tuName}
            | [] == typeArguments -> do
                return ty
            | otherwise -> do
                failTypeError pos $ Error.IllegalTypeApplication tuName
        TTypeFun tuParameters _rt
            | [] == typeArguments -> case typeApplicationPolicy of
                AllowTypeFunctions -> return ty
                DisallowTypeFunctions -> do
                    failTypeError pos $ Error.TypeApplicationMismatch typeName (length tuParameters) 0
            | length tuParameters == length typeArguments -> do
                (TTypeFun tuParameters' rt') <- instantiate env ty
                for_ (zip tuParameters' typeArguments) $ \(a, b) -> do
                    unify env pos a b
                return rt'
            | otherwise -> do
                failTypeError pos $ Error.TypeApplicationMismatch typeName (length tuParameters) (length typeArguments)
        _
            | [] == typeArguments ->
                return ty
            | otherwise ->
                -- TODO: make this error message sane
                failTypeError pos $ Error.IllegalTypeApplication (Text.pack $ show ty)


resolveArrayType :: Env -> Pos -> Mutability -> TC (TypeVar, TypeVar)
resolveArrayType env pos mutability = do
    elementType <- case mutability of
            Immutable -> freshType env
            Mutable -> freshWeakQVar env

    let typeReference = case mutability of
            Immutable -> KnownReference "array" "Array"
            Mutable -> KnownReference "mutarray" "MutableArray"
    arrayType <- resolveTypeReference env pos typeReference
    newArrayType <- applyTypeFunction env pos typeReference DisallowTypeFunctions arrayType [elementType]
    return (newArrayType, elementType)

resolveOptionType :: Env -> Pos -> TC (TypeVar, TypeVar)
resolveOptionType env pos = do
    elementType <- freshType env

    let typeReference = KnownReference "option" "Option"
    optionType <- resolveTypeReference env pos typeReference
    newOptionType <- applyTypeFunction env pos typeReference DisallowTypeFunctions optionType [elementType]
    return (newOptionType, elementType)

resolveBooleanType :: Env -> Pos -> TC TypeVar
resolveBooleanType env pos = do
    resolveTypeReference env pos (KnownReference "types" "Boolean")

resolveNumberType :: Env -> Pos -> TC TypeVar
resolveNumberType env pos = do
    resolveTypeReference env pos (KnownReference "number" "Number")

resolveStringType :: Env -> Pos -> TC TypeVar
resolveStringType env pos = do
    resolveTypeReference env pos (KnownReference "string" "String")

resolveVoidType :: Env -> Pos -> TC TypeVar
resolveVoidType env pos = do
    resolveTypeReference env pos (KnownReference "types" "Void")

resolveTupleType :: Env -> Pos -> [TypeVar] -> TC TypeVar
resolveTupleType env pos elements = do
    let tupleReference = KnownReference "tuple" $ "Tuple" <> (Text.pack $ show $ length elements)
    tupleType <- resolveTypeReference env pos tupleReference
    applyTypeFunction env pos tupleReference DisallowTypeFunctions tupleType elements

instantiateDataTypeDef' ::
    MonadIO m =>
    IORef (HashMap Int TypeVar) ->
    Env ->
    TDataTypeDef TypeVar ->
    m (TDataTypeDef TypeVar)
instantiateDataTypeDef' subst env def = do
    for def $ instantiate' subst env

instantiateDataTypeDef :: MonadIO m => Env -> TDataTypeDef TypeVar -> m (TDataTypeDef TypeVar)
instantiateDataTypeDef env def = do
    subst <- HashTable.new
    instantiateDataTypeDef' subst env def

instantiateField :: MonadIO m => IORef (HashMap Int TypeVar) -> Env -> RecordField TypeVar -> m (RecordField TypeVar)
instantiateField subst env RecordField{..} = do
    trTyVar' <- instantiate' subst env trTyVar
    let mut' = case trMut of
            RQuantified -> RFree
            _ -> trMut
    return RecordField{trName, trMut=mut', trTyVar=trTyVar'}

{-
instantiateRecord
    :: MonadIO m
    => IORef (HashMap Int TypeVar)
    -> Env
    -> [RecordField TypeVar]
    -> RecordOpen
    -> m TypeVar
instantiateRecord subst env rows open = do
    rows' <- for rows $ \RecordField{..} -> do
        rowTy' <- instantiate' subst env trTyVar
        let mut' = case trMut of
                RQuantified -> RFree
                _ -> trMut
        return RecordField{trName, trMut=mut', trTyVar=rowTy'}

    open' <- case open of
        RecordQuantified i constraint -> do
            constraint' <- for constraint $ instantiate' subst recordSubst env
            return $ RecordFree i constraint'
        RecordFree _ _ -> do
            fail $ "Instantiation of a free row variable -- this should never happen"
        RecordClose -> do
            return $ RecordClose

    objectType <- newIORef $ RRecord $ RecordType open' rows'
    return $ TRecord objectType
-}

instantiate' :: MonadIO m => IORef (HashMap Int TypeVar) -> Env -> TypeVar -> m TypeVar
instantiate' subst env ty = case ty of
    TypeVar ref -> do
        readIORef ref >>= \case
            TUnbound {} -> do
                -- TODO: should we instantiate record constraints here?
                -- We instantiate unbound type variables when recursively
                -- referencing a function whose parameter and return types are
                -- not yet quantified.
                return ty
            TBound tv' -> do
                instantiate' subst env tv'
    TQuant _ constraints name -> do
        HashTable.lookup name subst >>= \case
            Just v ->
                return v
            Nothing -> do
                -- TODO: propagate source
                -- TODO: instantiate record constraints
                tv <- freshTypeConstrained env constraints
                HashTable.insert name tv subst
                return tv
    TFun param ret -> do
        ty1 <- for param $ instantiate' subst env
        ty2 <- instantiate' subst env ret
        return $ TFun ty1 ty2
    TDataType def -> do
        typeVars' <- for (tuParameters def) $ instantiate' subst env
        return $ TDataType def{ tuParameters = typeVars' }
    TRecord fields -> do
        fields' <- for fields $ instantiateField subst env
        return $ TRecord fields'
    TTypeFun args rv -> do
        args' <- for args $ instantiate' subst env
        rv' <- instantiate' subst env rv
        return $ TTypeFun args' rv'

quantify :: MonadIO m => TypeVar -> m ()
quantify ty = case ty of
    TypeVar ref -> do
        readIORef ref >>= \case
            TUnbound Strong _ constraints i -> do
                writeIORef ref $ TBound $ TQuant Instantiation constraints i
            TUnbound Weak _ _ _ -> do
                return ()
            TBound t -> do
                quantify t
    TQuant {} -> do
        return ()
    TFun param ret -> do
        for_ param quantify
        quantify ret
    TDataType def ->
        for_ (tuParameters def) quantify
    TRecord fields -> do
        for_ fields $ \RecordField{..} -> do
            quantify trTyVar
    TTypeFun args rv -> do
        for_ args quantify
        quantify rv

instantiate :: MonadIO m => Env -> TypeVar -> m TypeVar
instantiate env t = do
    subst <- HashTable.new
    instantiate' subst env t

instantiateAll :: (MonadIO m, Traversable c) => Env -> c TypeVar -> m (c TypeVar)
instantiateAll env container = do
    subst <- HashTable.new
    for container $ instantiate' subst env

occurs :: Pos -> Int -> TypeVar -> TC ()
occurs pos tvn = \case
    TypeVar ref -> readIORef ref >>= \case
        TUnbound _ _ _ q | tvn == q -> do
            failTypeError pos OccursCheckFailed
        TUnbound {} -> do
            return ()
        TBound next -> do
            occurs pos tvn next
    TFun arg ret -> do
        for_ arg $ occurs pos tvn
        occurs pos tvn ret
    TDataType def -> do
        for_ (tuParameters def) $ occurs pos tvn
    TRecord fields -> do
        for_ fields $ \RecordField{..} ->
            occurs pos tvn trTyVar
    TQuant {} ->
        return ()
    TTypeFun args rv -> do
        for_ args $ occurs pos tvn
        occurs pos tvn rv

unificationError :: Pos -> String -> TypeVar -> TypeVar -> TC a
unificationError pos message a b = do
    failTypeError pos $ UnificationError message a b

lookupRecordField :: Name -> [RecordField t] -> Maybe (FieldMutability, t)
lookupRecordField name = \case
    [] -> Nothing
    (RecordField{..}:rest)
        | trName == name -> Just (trMut, trTyVar)
        | otherwise -> lookupRecordField name rest

unifyFieldConstraint :: Env -> Pos -> Maybe TypeVar -> RecordField TypeVar -> TC (RecordField TypeVar)
unifyFieldConstraint env pos constraint tr@RecordField{..} = do
    case constraint of
        Nothing -> return tr
        Just ctv -> do
            trMut' <- case trMut of
                RMutable -> failTypeError pos $ RecordMutabilityUnificationError trName "Row variable constraints don't support mutable fields"
                RImmutable -> return RImmutable
                RQuantified -> failTypeError pos $ RecordMutabilityUnificationError trName "Row variable constraints don't support mutable (even quantified) fields"
                RFree -> return RImmutable
            unify env pos ctv trTyVar
            return tr{ trMut=trMut' }

{-
unifyRecord :: Env -> Pos -> TypeVar -> TypeVar -> TC ()
unifyRecord env pos av bv = do
    -- do
    --     putStrLn " -- unifyRecord --"
    --     putStr "\t" >> showTypeVarIO av >>= putStrLn
    --     putStr "\t" >> showTypeVarIO bv >>= putStrLn

    let TRecord aRef = av
    let TRecord bRef = bv
    RecordType aOpen aRows <- followRecordTypeVar aRef
    RecordType bOpen bRows <- followRecordTypeVar bRef
    let aFields = sort $ map trName aRows
    let bFields = sort $ map trName bRows

    let coincidentRows = [(a, b) | a <- aRows, b <- bRows, trName a == trName b]
    let aOnlyRows = filter (\row -> trName row `notElem` bFields) aRows
    let bOnlyRows = filter (\row -> trName row `notElem` aFields) bRows
    let names trs = map trName trs

    coincidentRows' <- for coincidentRows $ \(lhs, rhs) -> do
        case unifyRecordMutability (trMut lhs) (trMut rhs) of
            Left err -> failTypeError pos $ RecordMutabilityUnificationError (trName lhs) err
            Right mut -> do
                unify env pos (trTyVar lhs) (trTyVar rhs)
                return RecordField
                    { trName = trName lhs
                    , trMut = mut
                    , trTyVar = trTyVar lhs
                    }

    let unifyRecordReversed = unifyRecord env pos bv av

    case (aOpen, bOpen) of
        -- closed and closed
        (RecordClose, RecordClose)
            | null aOnlyRows && null bOnlyRows -> do
                writeIORef bRef $ RRecord $ RecordType RecordClose coincidentRows'
                writeIORef aRef $ RBound $ bRef
            | otherwise ->
                unificationError pos "Closed row types must match exactly" av bv

        -- closed and free
        (RecordClose, RecordFree _ constraint)
            | null bOnlyRows -> do
                aOnlyRows' <- for aOnlyRows $ unifyFieldConstraint env pos constraint
                writeIORef aRef $ RRecord $ RecordType RecordClose (coincidentRows' ++ aOnlyRows')
                writeIORef bRef $ RBound $ aRef
            | otherwise ->
                unificationError pos (printf "Record has fields %s not in closed record" (show $ names bOnlyRows)) av bv
        (RecordFree _ _, RecordClose) -> do
            unifyRecordReversed

        -- closed and quantified
        (RecordClose, RecordQuantified _ _) ->
            unificationError pos "concrete record incompatible with record with explicit record type variable" av bv
        (RecordQuantified _ _, RecordClose) ->
            unifyRecordReversed

        -- free and free
        (RecordFree aVar constraintA, RecordFree _ constraintB) -> do
            aOnlyRows' <- for aOnlyRows $ unifyFieldConstraint env pos constraintB
            bOnlyRows' <- for bOnlyRows $ unifyFieldConstraint env pos constraintA
            newConstraint <- case (constraintA, constraintB) of
                (Nothing, Nothing) -> do
                    return Nothing
                (Just a, Nothing) -> do
                    return $ Just a
                (Nothing, Just b) -> do
                    return $ Just b
                (Just a, Just b) -> do
                    unify env pos a b
                    return $ Just a
            writeIORef bRef $ RRecord $ RecordType (RecordFree aVar newConstraint) (coincidentRows' ++ aOnlyRows' ++ bOnlyRows')
            writeIORef aRef $ RBound bRef

        -- free and quantified
        (RecordFree _ constraintA, RecordQuantified _ constraintB)
            | null aOnlyRows -> do
                writeIORef bRef $ RRecord $ RecordType bOpen (coincidentRows' ++ bOnlyRows)
                writeIORef aRef $ RBound bRef
            | otherwise ->
                error "lhs record has rows not in quantified record"
        (RecordQuantified _ _, RecordFree _ _) -> do
            unifyRecordReversed

        -- quantified and quantified
        (RecordQuantified a constraintA, RecordQuantified b constraintB)
            | not (null aOnlyRows) ->
                error "lhs quantified record has rows not in rhs quantified record"
            | not (null bOnlyRows) ->
                error "rhs quantified record has rows not in lhs quantified record"
            | a /= b ->
                error "Quantified records do not have the same qvar!"
            | otherwise -> do
                case (constraintA, constraintB) of
                    (Nothing, Nothing) -> pure ()
                    (Just atv, Just btv) -> unify env pos atv btv
                    _ -> error "invalid constraints"

                -- TODO: should we unify the constraint with the fields

                writeIORef aRef $ RRecord $ RecordType aOpen coincidentRows'
                -- Is this a bug? I copied it verbatim from what was here. -- chad
                writeIORef aRef $ RBound bRef
                {-
                writeTypeVar av (TRecord $ RecordType aOpen coincidentRows')
                writeTypeVar av (TBound bv)
                -}

    -- do
    --     putStrLn "\t -- after --"
    --     putStr "\t" >> showTypeVarIO av >>= putStrLn
    --     putStr "\t" >> showTypeVarIO bv >>= putStrLn
    --     putStrLn ""
-}

unifyConcreteRecord :: Env -> Pos -> [RecordField TypeVar] -> [RecordField TypeVar] -> TC ()
unifyConcreteRecord env pos fieldsA fieldsB = do
    let aFields = sort $ map trName fieldsA
    let bFields = sort $ map trName fieldsB

    let coincidentRows = [(a, b) | a <- fieldsA, b <- fieldsB, trName a == trName b]
    let aOnlyRows = filter (\row -> trName row `notElem` bFields) fieldsA
    let bOnlyRows = filter (\row -> trName row `notElem` aFields) fieldsB
    let names trs = map trName trs

    coincidentRows' <- for coincidentRows $ \(lhs, rhs) -> do
        case unifyRecordMutability (trMut lhs) (trMut rhs) of
            Left err -> failTypeError pos $ RecordMutabilityUnificationError (trName lhs) err
            Right mut -> do
                unify env pos (trTyVar lhs) (trTyVar rhs)
                return RecordField
                    { trName = trName lhs
                    , trMut = mut
                    , trTyVar = trTyVar lhs
                    }

    if null aOnlyRows && null bOnlyRows then
        return ()
    else
        unificationError pos "Closed row types must match exactly" undefined undefined -- fieldsA fieldsB

unifyRecordMutability :: FieldMutability -> FieldMutability -> Either Prelude.String FieldMutability
unifyRecordMutability m1 m2 = case (m1, m2) of
    (RFree, _) -> Right m2
    (_, RFree) -> Right m1
    (RImmutable, RImmutable) -> Right RImmutable
    (RImmutable, RMutable) -> Left "Record field mutability does not match"
    (RMutable, RMutable) -> Right RMutable
    (RMutable, RImmutable) -> Left "Record field mutability does not match"
    (RQuantified, _) -> Left "Quant!! D:"
    (_, RQuantified) -> Left "Quant2!! D:"

validateTraitConstraint :: Env -> Pos -> TypeVar -> TraitIdentity -> TraitDesc -> TC ()
validateTraitConstraint env pos typeVar traitIdentity traitDesc = case typeVar of
    TypeVar _ -> do
        fail "Internal Error: we already handled this case"
    TQuant _source (ConstraintSet _record traits) _tn -> do
        when (not $ Set.member traitIdentity traits) $ do
            failTypeError pos $ NoTraitOnType typeVar (tdName traitDesc) (tdModule traitDesc)
    TFun _ _ -> do
        fail "Functions do not implement traits (yet)"
    TDataType def -> do
        let key = (traitIdentity, dataTypeIdentity def)
        HashTable.lookup key (eKnownInstances env) >>= \case
            Just InstanceDesc{idTypeVar} -> do
                idTypeVar' <- instantiate env idTypeVar
                unify env pos idTypeVar' typeVar
                return ()
            Nothing -> do
                failTypeError pos $ NoTraitOnType typeVar (tdName traitDesc) (tdModule traitDesc)
    TRecord _fields -> do
        let key = (traitIdentity, RecordIdentity)
        HashTable.lookup key (eKnownInstances env) >>= \case
            Just InstanceDesc{..} -> do
                -- TODO: what do we do here?
                -- start unifying types with the field transformer?
                return ()
            Nothing -> do
                failTypeError pos $ NoTraitOnRecord typeVar (tdName traitDesc) (tdModule traitDesc)
    TTypeFun _ (TDataType def) -> do
        let key = (traitIdentity, dataTypeIdentity def)
        HashTable.lookup key (eKnownInstances env) >>= \case
            Just InstanceDesc{idTypeVar} -> do
                -- generalize this code with TDataType above
                idTypeVar' <- instantiate env idTypeVar
                unify env pos idTypeVar' typeVar
                return ()
            Nothing -> do
                failTypeError pos $ NoTraitOnRecord typeVar (tdName traitDesc) (tdModule traitDesc)
    TTypeFun _ _ -> do
        fail "Wat? Type functions definitely don't implement constraints"

-- TODO: how do we merge strength?
mergeStrength :: Strength -> Strength -> Strength
mergeStrength _left right = right

-- TODO: how do we merge level?
mergeLevel :: TypeLevel -> TypeLevel -> TypeLevel
mergeLevel _left right = right

mergeConstraints :: ConstraintSet -> ConstraintSet -> TC ConstraintSet
mergeConstraints (ConstraintSet recordA traitsA) (ConstraintSet recordB traitsB) = do
    -- TODO: implement merging record constraints
    let _ = recordA
    return $ ConstraintSet recordB $ traitsA <> traitsB

unify :: Env -> Pos -> TypeVar -> TypeVar -> TC ()
unify env pos av' bv' = do
    av <- followTypeVar av'
    bv <- followTypeVar bv'
    if av == bv then
        return ()
    else case (av, bv) of
        -- thanks to followTypeVar, the only TypeVar case here is TUnbound
        (TypeVar aref, TypeVar bref) -> do
            (TUnbound strengthA levelA constraintsA a') <- readIORef aref
            (TUnbound strengthB levelB constraintsB b') <- readIORef bref

            -- TODO: merge the constraints
            when ((constraintsA, a') /= (constraintsB, b')) $ do
                occurs pos a' bv
                writeIORef aref $ TBound bv
                let strength = mergeStrength strengthA strengthB
                let level = mergeLevel levelA levelB
                constraints <- mergeConstraints constraintsA constraintsB
                -- TODO: instead of mutating both, maybe introduce a new type var and bind both?
                writeIORef bref $ TUnbound strength level constraints b'
        (TypeVar _, _) -> do
            -- flip around so we only have to handle one case
            -- TODO: fix the error messages
            unify env pos bv av
        (_, TypeVar bref) -> do
            TUnbound _ _ (ConstraintSet _recordB traitsB) b' <- readIORef bref
            for_ (Set.toList traitsB) $ \traitIdentity@(TraitIdentity moduleName name) -> do
                (_, _, desc) <- resolveTraitReference env pos $ KnownReference moduleName name
                validateTraitConstraint env pos av traitIdentity desc
            occurs pos b' av
            writeIORef bref $ TBound av

        (TDataType ad, TDataType bd)
            | dataTypeIdentity ad == dataTypeIdentity bd -> do
                -- TODO: assert the two lists have the same length
                for_ (zip (tuParameters ad) (tuParameters bd)) $ uncurry $ unify env pos
            | otherwise -> do
                unificationError pos "" av bv

        (TRecord fieldsA, TRecord fieldsB) ->
            unifyConcreteRecord env pos fieldsA fieldsB

        (TFun aa ar, TFun ba br) -> do
            when (length aa /= length ba) $
                unificationError pos "" av bv

            for_ (zip aa ba) $ uncurry $ unify env pos
            unify env pos ar br

        (TQuant _ cI i, TQuant _ cJ j) | (cI, i) == (cJ, j) ->
            return ()

        _ ->
            unificationError pos "" av bv
