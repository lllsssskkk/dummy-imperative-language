module Analyzer (analyze) where

import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.Identity (Identity (runIdentity))
import Control.Monad.State (
    MonadState (get, state),
    StateT (runStateT),
 )
import Control.Monad.Writer (
    WriterT (runWriterT),
 )
import qualified Data.Map as Map

import Constant (VarName, lambdaSymbol)
import Program (Expr (..), Program, Statement (..))
import qualified System.IO as System

type SaEnv = (Map.Map String Int, [String])

type Sa a = StateT SaEnv (ExceptT String IO) a

increRefCount :: (VarName, Int) -> Sa ()
increRefCount (s, i) = state (\(table, list) -> ((), (Map.insert s i table, list)))

refPriorInitialization :: String -> Sa ()
refPriorInitialization varName = state (\(table, list) -> ((), (table, varName : list)))

parser :: Expr -> Sa ()
parser (Lambda _ _) = return ()
parser (Const _) = return ()
parser (Add e0 e1) = parseri e0 e1
parser (Sub e0 e1) = parseri e0 e1
parser (Mul e0 e1) = parseri e0 e1
parser (Div e0 e1) = parseri e0 e1
parser (And e0 e1) = parserb e0 e1
parser (Or e0 e1) = parserb e0 e1
parser (Not e0) = parser e0
parser (Eq e0 e1) = parserib e0 e1
parser (Gt e0 e1) = parserib e0 e1
parser (Lt e0 e1) = parserib e0 e1
parser (Var s) = do
    (env, _) <- get
    case Map.lookup s env of
        Just varRefNum -> increRefCount (s, 1 + varRefNum)
        Nothing -> refPriorInitialization s
    return ()

-- Int typed expressions
parseri :: Expr -> Expr -> Sa ()
parseri e0 e1 = parser e0 >> parser e1

-- Boolean typed expressions
parserb :: Expr -> Expr -> Sa ()
parserb e0 e1 = parser e0 >> parser e1

-- Operations over integers which produce booleans

parserib :: Expr -> Expr -> Sa ()
parserib e0 e1 = parser e0 >> parser e1

-- Check is the main body performs the static analysis functionality
-- Check responds to statements correspondingly

check :: Statement -> Sa ()
check (Call _fnName _inputs _varName) = return ()
check (Function _fnName _bindings expr) = parser expr
check Break = return ()
check (Seq s0 s1) = check s0 >> check s1
check (Assign s v) = do
    parser v
    increRefCount (s, 0)
check (Print e) = do
    parser $ Var e
    return ()
check (If cond s0 s1) = do
    parser cond
    check s0
    check s1
    return ()
check (While cond s) = do
    parser cond
    check s
check Pass = return ()

-- -- analyze is the run function of the static analysis part
-- -- analyze would print a list of unused variable name, if the program has no accessing error.
analyze :: Program -> IO ()
analyze program = do
    result <- runExceptT $ (runStateT $ check $ snd $ runIdentity (runWriterT program)) (Map.empty, [])
    case result of
        Right ((), (env, list)) -> do
            let unused = (++) lambdaSymbol $ (++ " are unused variables") $ show . Map.keys $ Map.filter (== 0) env
            let refPriorInit = (++) lambdaSymbol $ (++ " got referenced before initialization") $ show list
            System.putStrLn unused
            System.putStrLn refPriorInit
        Left exn -> System.print $ (++) lambdaSymbol ("Uncaught exception: " ++ exn)
