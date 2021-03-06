module Interpreter (run) where

import Prelude hiding (lookup, print)

import Control.Monad.Except (
  ExceptT,
  MonadError (throwError),
  MonadIO (liftIO),
  MonadTrans (lift),
  runExceptT,
 )
import Control.Monad.Identity (Identity (runIdentity))
import Control.Monad.Reader (
  MonadReader (ask),
  ReaderT (runReaderT),
 )
import Control.Monad.State (
  MonadState (get, state),
  StateT (runStateT),
 )
import Control.Monad.Writer (
  WriterT (runWriterT),
 )
import qualified Data.Map as Map
import qualified System.IO as System

import Constant (VarName, lambdaSymbol)
import Program (Expr (..), Program, Statement (..), Val (..))

type Env = Map.Map VarName Val

lookup :: MonadError String m => String -> Map.Map String a -> m a
lookup k t = case Map.lookup k t of
  Just x -> pure x
  Nothing -> throwError' ("Unknown variable " ++ k)

{-- Monadic style expression evaluator,
 -- with error handling and Reader monad instance to carry dictionary
 --}

type Eval a = ReaderT Env (ExceptT String Identity) a

runEval :: r -> ReaderT r (ExceptT e Identity) a -> Either e a
runEval env ex = runIdentity (runExceptT (runReaderT ex env))

--Integer typed expressions
evali :: (Int -> Int -> Int) -> Expr -> Expr -> ReaderT Env (ExceptT String Identity) Val
evali op e0 e1 = do
  e0' <- eval e0
  e1' <- eval e1
  case (e0', e1') of
    (I i0, I i1) -> pure $ I (i0 `op` i1)
    _ -> throwError' "type error in arithmetic expression"

--Boolean typed expressions
evalb :: (Bool -> Bool -> Bool) -> Expr -> Expr -> ReaderT Env (ExceptT String Identity) Val
evalb op e0 e1 = do
  e0' <- eval e0
  e1' <- eval e1
  case (e0', e1') of
    (B i0, B i1) -> pure $ B (i0 `op` i1)
    _ -> throwError' "type error in boolean expression"

--Operations over integers which produce booleans
evalib :: (Int -> Int -> Bool) -> Expr -> Expr -> ReaderT Env (ExceptT String Identity) Val
evalib op e0 e1 = do
  e0' <- eval e0
  e1' <- eval e1
  case (e0', e1') of
    (I i0, I i1) -> pure $ B (i0 `op` i1)
    _ -> throwError' "type error in arithmetic expression"

--Evaluate an expression
eval :: Expr -> Eval Val
eval (Lambda names expr) = pure $ Closure names expr
eval (Const v) = pure v
eval (Add e0 e1) = evali (+) e0 e1
eval (Sub e0 e1) = evali (-) e0 e1
eval (Mul e0 e1) = evali (*) e0 e1
eval (Div e0 e1) = evali div e0 e1
eval (And e0 e1) = evalb (&&) e0 e1
eval (Or e0 e1) = evalb (||) e0 e1
eval (Not e0) = evalb (const not) e0 (Const (B True))
--  where
--   not2 a _ = not a -- hack, hack
eval (Eq e0 e1) = evalib (==) e0 e1
eval (Gt e0 e1) = evalib (>) e0 e1
eval (Lt e0 e1) = evalib (<) e0 e1
eval (Var s) = do
  env <- ask
  lookup s env

type Run a = StateT Env (ExceptT String IO) a

set :: (VarName, Val) -> Run ()
set (s, i) = state (\table -> ((), Map.insert s i table))

step :: Statement -> Run ()
step (Function fnName bindings logic) = do
  set (fnName, Closure bindings logic)
step (Call fnName inputs varName) = do
  st <- get
  case runEval st (eval $ Var fnName) of
    Right (Closure names expr) -> do
      let localEnv = Map.fromList $ zip names inputs
      let env' = st <> localEnv
      case runEval env' (eval expr) of
        Right val -> do
          printStrLn $ "The return value of function " ++ fnName ++ " is : "
          printout val
          step (Assign varName $ Const val)
        Left err -> throwError' err
    Right _ -> throwError' "This is a function call, not expect variable name"
    Left _ -> throwError' $ fnName ++ " function is not defined yet"
step (Assign s v) =
  do
    st <- get
    case runEval st (eval v) of
      Right val -> set (s, val)
      Left err -> throwError' err
step (Seq s0 s1) = step s0 >> step s1
step (Print e) =
  do
    st <- get
    case runEval st (eval $ Var e) of
      Right val -> do
        printStr $ "The value inside " ++ e ++ " is : "
        printout val
      Left err -> throwError' err
step (If cond s0 s1) =
  do
    st <- get
    case runEval st (eval cond) of
      Right (B val) -> do
        if val then do step s0 else do step s1
      Right (I val) -> do throwError' $ "The if statement's condition shouldn't be an Int value " ++ show val
      Right (Double val) -> do throwError' $ "The if statement's condition shouldn't be an Double value " ++ show val
      Right (Closure _ _) -> do throwError' "The if statement's condition shouldn't be an function value "
      Left err -> throwError' err
step (While cond s) =
  do
    st <- get
    case runEval st (eval cond) of
      Right (B val) -> do
        if val
          then step s >> step (While cond s)
          else pure ()
      Right (I val) -> do throwError' $ "The while statement's condition shouldn't be an Int value " ++ show val
      Right (Double val) -> do throwError' $ "The if statement's condition shouldn't be an Int value " ++ show val
      Right (Closure _ _) -> do throwError' "The if statement's condition shouldn't be an function value "
      Left err -> throwError' err
step Break = do
  printStrLn "Enter a breakpoint"
  printStrLn "Enter \"Continue\" to exit the breakpoint"
  st <- get
  printStrLn $ (++) "Current variables : " $ show . Map.keys $ st
  instruction <- getInput
  case instruction of
    "Continue" -> pure ()
    _ -> do
      let variableValue = Map.lookup instruction st
      case variableValue of
        Just x -> do
          printout x
          step Break
        Nothing ->
          throwError' ("Unknown Variable : " ++ instruction)
step Pass = pure ()

printout :: Val -> Run ()
printout = lift . lift . System.print

printStr :: String -> Run ()
printStr = lift . lift . putStr

printStrLn :: String -> Run ()
printStrLn str = lift . lift . putStrLn $ lambdaSymbol ++ str

getInput :: Run String
getInput = liftIO System.getLine

throwError' :: MonadError [Char] m => [Char] -> m a
throwError' x = throwError $ lambdaSymbol ++ x

run :: Program -> IO ()
run program = do
  result <- runExceptT $ (runStateT $ step (snd $ runIdentity (runWriterT program))) Map.empty
  case result of
    Right (_, env) -> putStrLn $ (++) lambdaSymbol $ show env
    Left exn -> putStrLn (lambdaSymbol ++ "Uncaught exception: " ++ exn)
