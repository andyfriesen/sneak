{-# OPTIONS_GHC -F -pgmF htfpp #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}

module IntegrationTest where

import Control.Monad (when)
import Data.Monoid ((<>))
import qualified Crux.AST             as AST
import qualified Crux.JSBackend      as JS
import qualified Crux.Error as Error
import qualified Crux.Gen             as Gen
import qualified Crux.Module
import           Crux.Tokens          (Pos (..))
import           Crux.Typecheck.Types (TypeError (..), showTypeVarIO)
import qualified Data.HashMap.Strict  as HashMap
import           Data.Text            (Text)
import qualified Data.Text            as T
import qualified Data.Text.IO         as T
import           System.Exit          (ExitCode (..))
import           System.IO            (hFlush)
import           System.IO.Temp       (withSystemTempFile)
import           System.Process       (readProcessWithExitCode)
import           Test.Framework
import           Text.RawString.QQ    (r)
import qualified System.Directory.PathWalk as PathWalk
import qualified System.FilePath as FilePath
import System.Directory (doesDirectoryExist)

runProgram' :: AST.Program -> IO Text
runProgram' p = do
    m' <- Gen.generateProgram p
    let js = JS.generateJS m'
    withSystemTempFile "Crux.js" $ \path' handle -> do
        T.hPutStr handle js
        hFlush handle
        fmap T.pack $ do
            readProcessWithExitCode "node" [path'] "" >>= \case
                (ExitSuccess, stdout, _) -> return stdout
                (ExitFailure code, _, stderr) -> do
                    putStrLn $ "Process failed with code: " ++ show code ++ "\n" ++ stderr
                    putStrLn "Code:"
                    T.putStrLn js
                    fail $ "Process failed with code: " ++ show code ++ "\n" ++ stderr

run :: Text -> IO (Either Error.Error Text)
run src = do
    Crux.Module.loadProgramFromSource src >>= \case
        Left (_, e) -> return $ Left e
        Right m -> fmap Right $ runProgram' m

runMultiModule :: HashMap.HashMap AST.ModuleName Text -> IO (Either Error.Error Text)
runMultiModule sources = do
    Crux.Module.loadProgramFromSources sources >>= \case
        Left (_, e) -> return $ Left e
        Right m -> fmap Right $ runProgram' m

assertCompiles src = do
    result <- run $ T.unlines src
    case result of
        Right _ -> return ()
        Left err -> assertFailure $ "Compile failure: " ++ show err

assertOutput src outp = do
    result <- run $ T.unlines src
    case result of
        Right a -> assertEqual outp a
        Left err -> assertFailure $ "Compile failure: " ++ show err

assertUnificationError :: Pos -> String -> String -> Either Error.Error a -> IO ()
assertUnificationError pos a b (Left (Error.TypeError (UnificationError actualPos _ at bt))) = do
    assertEqual pos actualPos

    as <- showTypeVarIO at
    bs <- showTypeVarIO bt
    assertEqual a as
    assertEqual b bs

assertUnificationError _ _ _ _ =
    assertFailure "Expected a unification error"

failWithError :: String -> AST.ModuleName -> Error.Error -> IO ()
failWithError root moduleName err = do
    let moduleName' = AST.printModuleName moduleName
    let err' = Error.renderError err
    assertFailure $ "\nError in: " <> root <> "\nModule: " <> (T.unpack moduleName') <> "\n" <> err'

runIntegrationTest :: FilePath -> IO ()
runIntegrationTest root = do
    let mainPath = FilePath.combine root "main.cx"
    let stdoutPath = FilePath.combine root "stdout.txt"
    expected <- fmap T.pack $ readFile stdoutPath

    Crux.Module.loadProgramFromFile mainPath >>= \case
        Left (moduleName, err) -> do
            failWithError root moduleName err
        Right program -> do
            putStrLn $ "testing program " ++ mainPath
            stdout <- runProgram' program
            assertEqual expected stdout

test_integration_tests = do
    let integrationRoot = "tests/integration"
    exists <- doesDirectoryExist integrationRoot
    when (not exists) $ do
        fail $ "Integration test directory " ++ integrationRoot ++ " does not exist!"
    PathWalk.pathWalk integrationRoot $ \d _dirnames filenames -> do
        when ("main.cx" `elem` filenames) $ do
            runIntegrationTest d

test_let_is_not_recursive_by_default = do
    result <- run $ T.unlines [ "let foo = fun (x) { foo(x) }" ]
    assertEqual result $ Left $ Error.TypeError $ UnboundSymbol (Pos 1 1 21) "foo"

test_occurs_on_fun = do
    result <- run $ T.unlines
        [ "fun bad() { bad }"
        ]

    assertEqual (Left $ Error.TypeError $ OccursCheckFailed (Pos 1 1 1)) result

test_occurs_on_sum = do
    result <- run $ T.unlines
        [ "data List a { Cons(a, List a), Nil }"
        , "fun bad(a) { Cons(a, a) }"
        ]

    assertEqual (Left $ Error.TypeError $ OccursCheckFailed (Pos 1 2 14)) result

test_occurs_on_record = do
    result <- run $ T.unlines
        [ "fun bad(p) { { field: bad(p) } }"
        ]

    assertEqual (Left $ Error.TypeError $ OccursCheckFailed (Pos 1 1 1)) result

test_incorrect_unsafe_js = do
    result <- run $ T.unlines
        [ "let bad = _unsafe_js"
        ]
    assertEqual (Left $ Error.TypeError $ IntrinsicError (Pos 1 1 11) "Intrinsic _unsafe_js is not a value") result

test_annotation_is_checked = do
    result <- run $ T.unlines
        [ "let i: Number = \"hody\""
        ]

    assertUnificationError (Pos 1 1 1) "Number" "String" result

test_arrays_of_different_types_cannot_unify = do
    result <- run $ T.unlines
        [ "let _ = [[0], [\"\"]]"
        ]
    assertUnificationError (Pos 1 1 9) "Number" "String" result

test_record_annotation_is_checked2 = do
    result <- run $ T.unlines
        [ "let c: {} = _unsafe_js(\"console\")"
        , "fun main() {"
        , "    c.log(\"Hoop\")"
        , "}"
        , "let _ = main()"
        ]

    assertUnificationError (Pos 5 3 5) "{}" "{log: (TUnbound 15),..._16}" result
    -- assertEqual (Left "Unification error: Field 'log' not found in quantified record {} and {log: (TUnbound 6),f...}") result

test_cannot_assign_to_immutable_binding = do
    result <- run $ T.unlines
        [ "fun main() {"
        , "    let x = 2"
        , "    x = x + 1"
        , "    print(x)"
        , "}"
        , "let _ = main()"
        ]

    -- assertEqual (Left "Not an lvar: EIdentifier (IPrimitive Number) (Local \"x\")") result
    assertEqual (Left $ Error.TypeError $ NotAnLVar (Pos 5 3 5) "EIdentifier (IPrimitive Number) (Local \"x\")") result

test_cannot_assign_to_immutable_record_field = do
    result <- run $ T.unlines
        [ "fun main() {"
        , "    let a: {const x: Number} = {x: 44}"
        , "    a.x = 22"
        , "    print(a)"
        , "}"
        , "let _ = main()"
        ]

    assertEqual
        -- (Left "Not an lvar: ELookup (IPrimitive Number) (EIdentifier (IRecord (RecordType RecordClose [TypeRow {trName = \"x\", trMut = RImmutable, trTyVar = IPrimitive Number}])) (Local \"a\")) \"x\"")
        (Left $ Error.TypeError $ NotAnLVar (Pos 5 3 5) "ELookup (IPrimitive Number) (EIdentifier (IRecord (RecordType RecordClose [TypeRow {trName = \"x\", trMut = RImmutable, trTyVar = IPrimitive Number}])) (Local \"a\")) \"x\"")
        result

test_mutable_record_field_requirement_is_inferred = do
    result <- run $ T.unlines
        [ "fun swap(p) {"
        , "    let t = p.x"
        , "    p.x = p.y"
        , "    p.y = t"
        , "}"
        , "fun main() {"
        , "    let a: {const x: Number, const y: Number} = {x:44, y:0}"
        , "    swap(a)"
        , "}"
        , "let _ = main()"
        ]

    assertEqual
        (Left $ Error.TypeError $ RecordMutabilityUnificationError (Pos 5 8 5) "x" "Record field mutability does not match")
        result

test_polymorphic_type_annotations_are_universally_quantified2 = do
    rv <- run $ T.unlines
        [ "let f: (Number) -> Number = fun (i) { i }"
        , "let g: (a) -> a = fun (i) { i }"
        , "let _ = f(g(\"hello\"))"
        ]
    assertUnificationError (Pos 1 3 9) "Number" "String" rv

test_polymorphic_type_annotations_are_universally_quantified4 = do
    rv <- run $ T.unlines
        [ "let f: (a) -> Number = fun (i) { i }"
        ]
    assertUnificationError (Pos 1 1 1) "Number" "TQuant 7" rv

test_type_annotations_on_function_decls2 = do
    rv <- run $ T.unlines
        [ "fun id_int(x: a): Number { x }"
        ]
    assertUnificationError (Pos 1 1 1) "Number" "TQuant 10" rv

test_escaped_strings = do
    result1 <- run $ T.unlines
        [ [r|let _ = print("\0\a\b\f\n\r\t\v\\\'\"\?")|]
        ]
    assertEqual (Right "\NUL\a\b\f\n\r\t\v\\'\"?\n") result1

    result2 <- run $ T.unlines
        [ [r|let _ = print("\x00\x01\x02")|]
        ]
    assertEqual (Right "\0\1\2\n") result2

    -- TODO: tests for \u and \U

test_cannot_omit_arguments = do
    result <- run $ T.unlines
        [ "fun f(x) {}"
        , "let _ = f()"
        ]
    assertUnificationError (Pos 1 2 9) "((TUnbound 14)) -> Unit" "() -> Unit" result

test_exported_sum_cannot_depend_on_non_exported_type = do
    result <- runMultiModule $ HashMap.fromList
        [ ( "A", T.unlines
            [ "data A {}"
            , "export data B { B(A) }"
            ]
          )
        , ("main", T.unlines
            [ "import { A(...) }"
            ]
          )
        ]
    err <- assertLeft result
    case err of
        Error.TypeError (ExportError _pos message) ->
            assertEqual "Variant \"B\" of exported data type \"B\" depends on nonexported data type \"A\" (defined at 1,1)" message
        _ ->
            assertFailure $ "Expected ExportError but got " ++ show err
