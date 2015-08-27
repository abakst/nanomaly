{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns   #-}
{-# LANGUAGE BangPatterns     #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE ViewPatterns     #-}
module NanoML.Step where

import Control.Applicative
import Control.Exception
import Control.Monad.Except
import Control.Monad.State
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Graph.Inductive.Dot as Graph
import qualified Data.Graph.Inductive.Graph as Graph
import qualified Data.Graph.Inductive.PatriciaTree as Graph
import Data.List
import Data.Foldable
import qualified Data.IntMap as IntMap
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid hiding (Alt)
import qualified Data.Sequence as Seq
import qualified Data.Vector as Vector
import System.Mem.StableName
import Text.Printf

import NanoML.Eval
import NanoML.Misc
import NanoML.Parser
import NanoML.Pretty
import NanoML.Prim
import NanoML.Types

import Debug.Trace

writeTrace :: String -> Seq.Seq Event -> IO ()
writeTrace p tr = LBS.writeFile "../OnlinePythonTutor/v3/test-trace.js"
                                ("var trace = " <> Aeson.encode obj)
  where
  obj = Aeson.object [ "code" Aeson..= p, "trace" Aeson..= short ]
  short = map head
        $ groupBy eqSpan
        $ toList tr
  eqSpan x y =  evt_line x == evt_line y && evt_column x == evt_column y
             && evt_expr_width x == evt_expr_width y
             && evt_event x == evt_event y

runStep opts x = case runEvalFull opts x of
  (Left e, st, _)  -> traceShow e $ stTrace st
  (Right v, st, _) -> stTrace st

----------------------------------------------------------------------
-- Working with the reduction graph
----------------------------------------------------------------------

type Graph = Graph.Gr Expr EdgeKind
type Node  = Graph.LNode Expr
type Edge  = Graph.LEdge EdgeKind

runGraph opts x = case runEvalFull opts x of
  (Left e, st, _)  -> Left $ (e, stTrace st, stEdges st, stCurrentExpr st)
  (Right v, st, _) -> Right $ stEdges st

mkPaths st = do
  let expr = stCurrentExpr st
  let edges = stEdges st
  gr <- buildGraph edges
  root <- findRoot gr expr

  let check (Val _ v) t =
        case runEval stdOpts (put st >> unify (typeOf v) t) of
          Left _ -> False
          Right _ -> True

  -- with a single subterm we always prioritize it over the parent
  let checkOne x = findRoot gr x >>= \xn -> return [mkPath gr xn, mkPath gr root]

  -- otherwise we order as follows
  -- 1. subterms that don't unify on their own
  -- 2. subterms that constribute to inconsistent instantiation of tyvars
  --    e.g. in `1 :: [true]` we would have `a ~ int` and `a ~ bool`
  -- 3. the parent term
  -- 4. subterms that unify
  let checkMany xts = do
        let bad  = filter (not . uncurry check) xts
        let poly = [] -- FIXME: check that all tyvars can be consistently instantiated
        ns <- mapM (findRoot gr) (nub $ map fst bad ++ map fst poly ++ [expr] ++ map fst xts)
        return $ map (mkPath gr) ns
  
  case expr of
    Uop _ u x -> checkOne x
    Bop _ b x y -> checkMany [(x, typeOfBop b), (y, typeOfBop b)]
    ConApp  _ c (Just x)
      -> let ts = dArgs $ stDataEnv st Map.! c
         in case (x, ts) of
              (_, [t]) -> checkOne x
                                                                -- FIXME: this creates a new object and breaks the graph...
              (Val ms (VT _ _ vs _), _) -> checkMany $ zip (map (Val ms) vs) ts
    Record _ fs
      -> let TRec fts = tyRhs $ stFieldEnv st Map.! fst (head fs)
         in checkMany [ (fromJust $ lookup f fs, t) | (f, _, t) <- fts ]
    Case _ x as -> checkOne x
    Prim1 _ p@(P1 _ f t) x -> checkOne x
    Prim2 _ p@(P2 _ f tx ty) x y -> checkMany [(x, tx), (y, ty)]
    _ -> error $ "mkPaths impossible: " ++ show expr


buildGraph :: [(Expr, EdgeKind, Expr)] -> IO Graph
buildGraph tr = do
  nodes <- concatMapM mkNode tr
--  print (length nodes, length (nub nodes))
  edges <- mapM mkEdge tr
  return $ Graph.mkGraph (nub nodes) (nub edges)
  where
  mkNode (x, k, y) = do
    xn <- makeStableName =<< evaluate x
    yn <- makeStableName =<< evaluate y
    return [(hashStableName xn, x), (hashStableName yn, y)]
  mkEdge (x, k, y) = do
    xn <- makeStableName =<< evaluate x
    yn <- makeStableName =<< evaluate y
    return (hashStableName xn, hashStableName yn, k)

findRoot :: Graph -> Expr -> IO Graph.Node
findRoot gr e = do
  en <- makeStableName =<< evaluate e
  let p (n,x) = do xn <- makeStableName =<< evaluate x
                   return (xn == en)
  fst . fromJust <$> findM p (Graph.labNodes gr)

isStepsTo = (==StepsTo)

isSubTerm (SubTerm _) = True
isSubTerm _           = False

-- | Follow the 'StepsTo' relation forward once from a node.
forwardstep :: Graph -> Graph.Node -> Maybe Graph.Node
forwardstep gr n = case find (isStepsTo . snd) $ Graph.lsuc gr n of
  Nothing      -> Nothing
  Just (n', _) -> Just n'

-- | Follow the 'StepsTo' relation as far back as possible from a node.
backjump :: Graph -> Graph.Node -> Maybe Graph.Node
backjump gr n = case find (isStepsTo . snd) $ Graph.lpre gr n of
  Nothing      -> Nothing
  Just (n', _) -> backjump gr n' <|> Just n'

-- | Find the 'SubTerm's of a node.
subterms :: Graph -> Graph.Node -> [Graph.Node]
subterms gr n = map fst . filter (isSubTerm . snd) $ Graph.lsuc gr n

candidates :: Graph -> Graph.Node -> [Graph.Node]
candidates gr n = maybeToList (forwardstep gr n)
               ++ mapMaybe (backjump gr) (subterms gr n)

bfs :: Graph -> Graph.Node -> [Graph.Node]
bfs gr n = go [n]
  where
  go []     = []
  go (x:xs) = x : go (xs ++ candidates gr x)

  -- next ++ concatMap (bfs gr) next -- FIXME: this doesn't look right..
  -- where next = candidates gr n

dfs :: Graph -> Graph.Node -> [Graph.Node]
dfs gr n = n : concatMap (dfs gr) (candidates gr n)

search :: Graph -> Graph.Node -> SrcSpan
       -> (Graph -> Graph.Node -> [Graph.Node])
       -> [Graph.Node]
search gr root target strat =
  case span notTarget walk of
    (xs, t:_) -> xs ++ [t]
  where
  walk = strat gr root
  notTarget n = case getSrcSpanMaybe . fromJust $ Graph.lab gr n of
    Nothing -> True
    Just ss -> ss /= target

-- | Compute all "interesting" paths involving a term.
--
-- 1. The 'StepsTo' path that leads to the term itself.
-- 2. The 'StepsTo' paths that lead to the term's immediate subterms.
paths :: Graph -> Graph.Node -> [Graph.Path]
paths gr root = map (mkPath gr) (root : subterms gr root)

mkPath gr n = go (backjump gr n) []
  where
  go Nothing  p = p
  go (Just n) p = go (forwardstep gr n) (p ++ [n])

----------------------------------------------------------------------
-- Stepping
----------------------------------------------------------------------
stepAll expr = do
  --traceShowM $ pretty expr
  expr' <- step expr
  if isVal expr'
     then return expr'
     else stepAll expr'

stepAllProg [] = return ()
stepAllProg (d:p) = do
--  traceShowM $ pretty d
  md <- stepDecl d `catchError` \e -> addUncaughtException e >> throwError e
  case md of
    Nothing -> stepAllProg p
    Just d  -> stepAllProg (d:p)

stepDecl :: MonadEval m => Decl -> m (Maybe Decl)
stepDecl decl = case decl of
  DFun ss Rec    binds -> do
    setVarEnv =<< evalRecBinds binds
    return Nothing
  DFun ss NonRec binds -> do
    let (ps, es) = unzip binds
    r <- stepOne es
         (\vs -> Nothing <$ (setVarEnv =<< evalNonRecBinds (zip ps vs)))
         (\es -> return . Just $ DFun ss NonRec (zip ps es))
    gcScopes r
    return r
  DEvl ss expr
    | isVal expr -> return Nothing
    | otherwise  -> do
        e <- step expr
        env <- gets stVarEnv
        -- addEdge StepsTo expr e
        -- -- traceShowM (pretty expr)
        -- -- traceShowM (pretty e)
        -- -- traceShowM expr
        -- -- traceShowM e
        -- -- addEdge StepsTo expr e
        -- case exprDiff env expr e of
        --   Nothing -> traceShowM "no diff" >> traceShowM (pretty expr) >> traceShowM (pretty e) >> traceShowM ""
        --   Just (env, before, after, kind) -> do
        --     traceShowM (pretty before)
        --     traceShowM (pretty after)
        --     traceShowM ""
        --     addEvent before after kind (getSrcSpanExprMaybe expr) `withEnv` env
        --     unless (kind == Return) $ addEdge StepsTo before after
        --     -- TODO: need to add StepsTo edges for all sub-terms along the path to the changed term
        --     -- see, e.g., the `1 + 2` sub-term in evaluation of `1 + 2 + 3`
        gcScopes e
        -- traceM ""
        return (Just $ DEvl ss e)
  DTyp _ decls -> mapM_ addType decls >> return Nothing
  DExn _ decl -> extendType "exn" decl >> return Nothing

-- stepNonRecBinds binds = do
--   env <- evalNonRecBinds

build :: MonadEval m => Expr -> Expr -> m Expr
build before after = do
  addEvent before after StepLine (getSrcSpanExprMaybe before) -- kind (getSrcSpanExprMaybe expr) `withEnv` env
  addEdge StepsTo before after
  addSubTerms after
  return after

step :: MonadEval m => Expr -> m Expr
step expr = withCurrentExpr expr $ case expr of
  Val _ v -> return expr
  -- With ms env e
  --   | isVal e   -> return e
  --   | otherwise -> do
  --       e' <- step e `withEnv` env
  --       build expr $ With ms env e'
  With ms env e
    | isVal e   -> return e
    | otherwise -> do
        e' <- step e `withEnv` env
        if isVal e'
          then build expr e'
          else build expr $ With ms env e'
  Replace ms env e
    | isVal e   -> return e
    | otherwise -> do
        e' <- step e `withEnv` env
        if isVal e'
          then build expr e'
          else build expr $ Replace ms env e'
        -- build expr $ Replace ms env e'
  Var ms v -> do
    -- addEvent expr
    build expr =<< fmap (Val ms) . lookupEnv v =<< gets stVarEnv
  Lam ms _ _ -> withCurrentProvM $ \prv -> -- addEvent expr >>
    Val ms . VF prv . Func expr <$> gets stVarEnv
  App ms f args -> stepOne (f:args)
                  (\(f:args) -> -- addEvent expr >> 
                                build expr =<< stepApp ms f args)
                  (\(f:args) -> build expr $ App ms f args)
  Bop ms b e1 e2 -> stepOne [e1,e2]
                   (\[v1,v2] -> -- addEvent expr >> 
                                build expr =<< stepBop ms b v1 v2)
                   (\[e1,e2] -> build expr $ Bop ms b e1 e2)
  Uop ms u e
    | isVal e   -> build expr =<< stepUop ms u e
    | otherwise -> build expr =<< Uop ms u <$> step e
  Lit ms l -> build expr =<< Val ms <$> litValue l
  Let ms Rec binds body -> do
    env <- evalRecBinds binds
    build expr $ With ms env body
    -- let (ps, es) = unzip binds
    -- env <- gets stVarEnv
    -- stepOne es
    --   (\vs -> do fenv <- foldr joinEnv env <$> zipWithM matchPat vs ps
    --              )
    --   (\es -> return $ Let Rec (zip ps es) body)
  Let ms NonRec binds body -> do
    let (ps, es) = unzip binds
    stepOne es
      (\vs -> do env <- evalNonRecBinds (zip ps vs)
                 build expr $ With ms env body
      )
      (\es -> build expr $ Let ms NonRec (zip ps es) body)
  Ite ms b t f
    | Val _ b <- b
      -> -- addEvent expr >>
      case b of
          VB _ True  -> build expr t
          VB _ False -> build expr f
    | otherwise
      -> do b <- step b
            build expr $ Ite ms b t f
  Seq ms e1 e2
    | isVal e1  -> -- addEvent expr >>
      build expr e2
    | otherwise -> build expr =<< (\e1 -> Seq ms e1 e2) <$> step e1
  Case ms e as
    | isVal e   -> -- addEvent expr >> 
      build expr =<< stepAlts e as
    | otherwise -> build expr =<< (\e -> Case ms e as) <$> step e
  Tuple ms es -> stepOne es
                (\vs -> withCurrentProvM $ \prv ->
                  build expr $ Val ms $ VT prv (length vs) (map unVal vs) (map (typeOf . unVal) vs))
                (\es -> build expr $ Tuple ms es)
  ConApp ms dc Nothing -> do
    build expr =<< Val ms <$> evalConApp dc Nothing
  ConApp ms dc (Just e)
    | Val _ v <- e -> build expr =<< Val ms <$> evalConApp dc (Just v)
    | otherwise  -> build expr =<< ConApp ms dc . Just <$> step e
  Record ms flds
    | all (isVal . snd) flds -> do
      td@TypeDecl {tyCon, tyRhs = TRec fs} <- lookupField $ fst $ head flds
      (vs, sus) <- fmap unzip $ forM fs $ \ (f, m, t) -> do
        let Val _ v = fromJust $ lookup f flds
        force v t $ \v su -> do
          su <- unify t (typeOf v)
          i <- fresh
          writeStore i (m,v)
          return ((f,i),su)
      let t = subst (mconcat sus) $ typeDeclType td
      withCurrentProvM $ \prv -> build expr $ Val ms $ VR prv vs t
    | otherwise -> do
      td@TypeDecl {tyCon, tyRhs = TRec fs} <- lookupField $ fst $ head flds
      unless (all (`elem` map fst3 fs) (map fst flds)) $
        otherError $ printf "invalid fields for type %s: %s" tyCon (show $ pretty expr)
      unless (all (`elem` map fst flds) (map fst3 fs)) $
        otherError $ printf "missing fields for type %s: %s" tyCon (show $ pretty expr)
      let (fs, es) = unzip flds
      stepOne es
        (error "step.Record: impossible")
        (\es -> build expr $ Record ms $ zip fs es)
  Field ms e f
    | Val _ v <- e -> build expr =<< Val ms <$> getField v f
  SetField ms r f e -> stepOne [r,e]
                      (\[Val _ vr, Val _ ve] -> setField vr f ve >> withCurrentProvM (build expr . Val ms . VU))
                      (\[r,e] -> build expr $ SetField ms r f e)
  Array ms [] -> withCurrentProvM $ \prv -> build expr $ Val ms (VV prv Vector.empty (TVar "a"))
  Array ms es -> stepOne es
                (\(map unVal -> (v:vs)) -> do
                    mapM_ (unify (typeOf v) . typeOf) vs
                    withCurrentProvM $ \prv -> build expr (Val ms (VV prv (Vector.fromList (v:vs)) (typeOf v))))
                (\es -> build expr $ Array ms es)
  Try ms e alts
    | isVal e   -> build expr e
    | otherwise -> do
        env <- gets stVarEnv
        build expr =<< (\e -> Try ms e alts) <$> step e `catchError` \e -> do
          setVarEnv env
          case e of
            MLException ex -> build expr =<< stepAlts (Val ms ex) alts
            _              -> Val ms <$> maybeThrow e
  Prim1 ms p@(P1 x f t) e
    | Val _ v <- e -> build expr =<< (fmap (Val ms) . force v t $ \v su -> f v)
    | otherwise  -> build expr =<< Prim1 ms p <$> step e
  Prim2 ms p@(P2 x f t1 t2) e1 e2 ->
    stepOne [e1,e2]
      (\[Val _ v1, Val _ v2] -> build expr =<< (fmap (Val ms) . forces [(v1,t1),(v2,t2)] $ \[v1,v2] su -> f v1 v2))
      (\[e1,e2] -> build expr (Prim2 ms p e1 e2))
  _ -> error (show expr)

stepApp :: MonadEval m => MSrcSpan -> Expr -> [Expr] -> m Expr
stepApp ms (Val _ f) es = case f of
  VF _ (Func (Lam {}) env) -> do
        let (ps, e, env) = gatherLams f
            (eps, es', ps') = zipWithLeftover es ps
        -- traceShowM (eps, es', ps')
        Just pat_env <- mconcat <$> mapM (\(Val _ v, p) -> matchPat v p) eps
        -- traceShowM pat_env
        -- traceM ""
        -- pushEnv env
        -- pushEnv pat_env
        nenv <- allocEnvWith ("app:" ++ show (srcSpanStartLine $ fromJust ms)) env pat_env
        case (ps', es') of
          ([], []) -> Replace ms nenv <$> refreshExpr (onSrcSpanExpr (<|> ms) e) -- only refresh at saturated applications
          ([], _) -> Replace ms nenv <$> addSubTerms (App ms e es')
          (_, []) -> withCurrentProvM $ \prv -> mkLamsSubTerms ps' e >>= \l -> return $ Val ms (VF prv (Func l nenv)) -- WRONG?? mkLamsSubTerms ps' e
  _ -> otherError $ printf "'%s' is not a function" (show f)
stepApp _ f es = error (show (f:es))

mkLamsSubTerms [] e = return e
mkLamsSubTerms (p:ps) e = do
  x <- mkLamsSubTerms ps e
  addSubTerms $ Lam (mergeLocated p x) p x

zipWithLeftover = go []
  where
  go xys xs     []     = (reverse xys, xs, [])
  go xys []     ys     = (reverse xys, [], ys)
  go xys (x:xs) (y:ys) = go ((x,y):xys) xs ys

-- stepApp (Val f) (map unVal -> vs) = do
--   let (ps, e, env) = gatherLams f
--   let (hd, tl) = splitAt (length ps) vs
--   Just pat_env <- mconcat <$> zipWithM matchPat hd ps
--   case tl of
--           -- this doesn't seem right..
--     [] -> return e -- step e `withExtendedEnv` joinEnv pat_env env
--     --vs ->

--stepBop :: MonadEval m => Bop -> Expr -> Expr -> m Expr
stepBop ms bop (Val _ v1) (Val _ v2) = Val ms <$> evalBop bop v1 v2

--stepUop :: MonadEval m => Uop -> Expr -> m Expr
stepUop ms uop (Val _ v) = Val ms <$> evalUop uop v

stepAlts :: MonadEval m => Expr -> [Alt] -> m Expr
stepAlts _ []
  = withCurrentProvM $ \prv ->
    fmap (Val Nothing) . maybeThrow $ MLException (mkExn "Match_failure" [] prv)
stepAlts (Val ms v) ((p,g,e):as)
  = matchPat v p >>= \case
      Nothing  -> stepAlts (Val ms v) as
      Just bnd -> do bnd <- allocEnv ("match:" ++ show (srcSpanStartLine $ fromJust ms)) bnd
                     case g of
                      Nothing -> return $ With ms bnd e
                      Just g  -> do
                        eval g `withEnv` bnd >>= \case
                          VB _ True  -> return $ With ms bnd e
                          VB _ False -> stepAlts (Val ms v) as

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------

stepOne :: MonadEval m
        => [Expr]          -- ^ possible expressions to step through
        -> ([Expr] -> m a) -- ^ what to do when they're all values
        -> ([Expr] -> m a) -- ^ what to do after stepping a single expression
        -> m a
stepOne es kv ke = do
  let (vals, exprs) = span isVal es
  case exprs of
    []     -> kv vals
    (e:es) -> do
      v <- step e
      ke (vals ++ v : es)

-- single :: Functor m => m a -> m [a]
-- single = fmap (:[])

-- choose :: MonadEval m => [Expr] -> ([Expr] -> m Expr) -> m [Expr]
-- choose exprs k = go exprs []
--   where
--   -- go :: MonadEval m => [Expr] -> [Expr] -> m [Expr]
--   go []     !vals = single (k vals)
--   go (e:es) !vals
--     | isVal e     = go es (vals ++ [e])
--     | otherwise   = do vs <- step e
--                        concatMapM (\v -> do x <- k (vals ++ v : es)
--                                             (x:) <$> go es (vals ++ [v])
--                                   ) vs


isVal :: Expr -> Bool
isVal (Val _ _)  = True
isVal _          = False

unVal :: Expr -> Value
unVal (Val _ v) = v

spanVals :: [Expr] -> ([Value],[Expr])
spanVals xs = let (vs,es) = span isVal xs
              in (map unVal vs, es)

gatherLams :: Value -> ([Pat], Expr, Env)
gatherLams (VF _ (Func (Lam _ p e) env)) = go [p] e
  where
  go ps (Lam _ p e) = go (p:ps) e
  go ps e           = (reverse ps, e, env)


addEvent :: MonadEval m => Expr -> Expr -> Kind -> MSrcSpan -> m ()
addEvent bf (With _ env expr) k ms = addEvent bf expr k ms `withEnv` env
addEvent bf (Replace _ env expr) k ms = addEvent bf expr k ms `withEnv` env
addEvent bf expr k (Just loc)
  | interesting expr || k == Return = do
  let line = srcSpanStartLine loc
  let column = srcSpanStartCol loc
  let expr_width = srcSpanWidth loc
  let event = showKind k
  let stdout = ""
  let func_name = "<top-level>"
  id <- envId <$> gets stVarEnv
  -- traceShowM (k, id, expr)
  let insertReturn 
        | Return <- k = insertEnv "__return__" (unVal expr)
        | otherwise   = \x -> x
  envs <- IntMap.elems . IntMap.delete 0 . IntMap.adjust insertReturn id <$> gets stEnvMap
--  let Env benv = baseEnv
  -- traceShowM (pretty expr, length envs)
  let genv = [] -- envEnv $ last envs
  let ordered_globals = reverse $ map fst genv
  let globals = Map.fromList genv
  let heap = IntMap.empty
  let stack = mkStack id envs -- (init envs)
  -- traceShowM stack
  let evt = Event { evt_ordered_globals = ordered_globals
                  , evt_stdout = stdout
                  , evt_func_name = func_name
                  , evt_stack_to_render = stack
                  , evt_globals = globals
                  , evt_heap = heap
                  , evt_line = line
                  , evt_column = column - 1
                  , evt_expr_width = expr_width
                  , evt_event = event
                  , evt_exception_msg = ""
                  , evt_before = bf
                  , evt_after = expr
                  }
  modify' $ \s -> s { stTrace = stTrace s Seq.|> evt }
addEvent _ _ _ _ = return ()

addUncaughtException :: MonadEval m => NanoError -> m ()
addUncaughtException exn = do
  last_evt <- gets (last . toList . stTrace)
  let evt = last_evt { evt_event = "uncaught_exception"
                     , evt_exception_msg = show (pretty exn)
                     , evt_before = evt_after last_evt
                     }
  modify' $ \s -> s { stTrace = stTrace s Seq.|> evt }

addCall :: MonadEval m => Expr -> m ()
-- addCall expr
--   | Just loc <- getSrcSpanMaybe expr = do
--   -- traceShowM $ pretty expr
--   let line = srcSpanStartLine loc
--   let column = srcSpanStartCol loc
--   let expr_width = srcSpanWidth loc
--   let event = "call"
--   let stdout = ""
--   let func_name = "<top-level>"
--   id <- envId <$> gets stVarEnv
--   envs <- IntMap.elems . IntMap.delete 0 <$> gets stEnvMap
-- --  let Env benv = baseEnv
--   -- traceShowM ("call", pretty expr, length envs)
--   let genv = [] -- envEnv $ last envs
--   let ordered_globals = reverse $ map fst genv
--   let globals = Map.fromList genv
--   let heap = IntMap.empty
--   let stack = mkStack id envs -- (init envs)
--   -- traceShowM ("call", stack)

--   let evt = Event { evt_ordered_globals = ordered_globals
--                   , evt_stdout = stdout
--                   , evt_func_name = func_name
--                   , evt_stack_to_render = stack
--                   , evt_globals = globals
--                   , evt_heap = heap
--                   , evt_line = line
--                   , evt_column = column - 1
--                   , evt_expr_width = expr_width
--                   , evt_event = event
--                   , evt_expr = expr
--                   }
--   modify' $ \s -> s { stTrace = stTrace s Seq.|> evt }
addCall _ = return ()

addReturn :: MonadEval m => Expr -> m ()
-- addReturn expr
--   | Just loc <- getSrcSpanMaybe expr = do
--   -- traceShowM $ pretty expr
--   let line = srcSpanStartLine loc
--   let column = srcSpanStartCol loc
--   let expr_width = srcSpanWidth loc
--   let event = "return"
--   let stdout = ""
--   let func_name = "<top-level>"
--   id <- envId <$> gets stVarEnv
--   envs <- IntMap.elems . IntMap.delete 0 . IntMap.adjust (insertEnv "__return__" (unVal expr)) id <$> gets stEnvMap
--   -- traceShowM (id, map envId envs)
-- --  let Env benv = baseEnv
--   -- traceShowM ("return", pretty expr, length envs)
--   let genv = [] -- envEnv $ last envs
--   let ordered_globals = reverse $ map fst genv
--   let globals = Map.fromList genv
--   let heap = IntMap.empty
--   let stack = mkStack id envs -- (init envs)
--   -- traceShowM stack

--   let evt = Event { evt_ordered_globals = ordered_globals
--                   , evt_stdout = stdout
--                   , evt_func_name = func_name
--                   , evt_stack_to_render = stack
--                   , evt_globals = globals
--                   , evt_heap = heap
--                   , evt_line = line
--                   , evt_column = column - 1
--                   , evt_expr_width = expr_width
--                   , evt_event = event
--                   , evt_expr = expr
--                   }
--   modify' $ \s -> s { stTrace = stTrace s Seq.|> evt }
addReturn _ = return ()

mkStack :: Ref -> [Env] -> [Scope]
mkStack id env = markParents (map (mkScope id) env)
  -- s : ss -> s { scp_is_highlighted = True } : ss
  -- ss -> ss

mkScope :: Ref -> Env -> Scope
mkScope id e = Scope
  { scp_frame_id = envId e
  , scp_encoded_locals = Map.fromList $ envEnv e
  , scp_is_highlighted = envId e == id
  , scp_is_parent = False
  , scp_func_name = envName e
  , scp_is_zombie = False
  , scp_parent_frame_id_list = maybe [] (\p -> [envId p] \\ [0]) (envParent e) -- (\\[0]) . map envId . tail $ toListEnv e
  , scp_unique_hash = mkHash e
  , scp_ordered_varnames = reverse $ map fst (envEnv e)
  }

mkHash :: Env -> String
mkHash e = envName e ++ "_f" ++ show (envId e)

markParents :: [Scope] -> [Scope]
markParents []     = []
markParents (s:ss) = s' : ss'
  where
  ss' = markParents ss
  s'  = if any (\p -> scp_frame_id s `elem` scp_parent_frame_id_list p) ss'
        then s { scp_is_parent = True, scp_unique_hash = scp_unique_hash s ++ "_p" }
        else s

gcScopes :: (MonadEval m, CollectEnvIds a) => a -> m ()
gcScopes expr = do
  let ids = collectEnvIds expr
  envMap <- gets stEnvMap
  modify' $ \s -> s { stEnvMap = IntMap.filterWithKey (\k _ -> k `elem` ids) (stEnvMap s) }

interesting expr = case expr of
  Val {} -> False
  Var {} -> False
  _      -> True

instance Aeson.ToJSON Event where
  toJSON Event {..} = Aeson.object
    [ "ordered_globals" Aeson..= Aeson.toJSON evt_ordered_globals
    , "stdout"          Aeson..= Aeson.toJSON evt_stdout
    , "func_name"       Aeson..= Aeson.toJSON evt_func_name
    , "stack_to_render" Aeson..= Aeson.toJSON evt_stack_to_render
    , "globals"         Aeson..= Aeson.toJSON evt_globals
    , "heap"            Aeson..= Aeson.toJSON evt_heap
    , "line"            Aeson..= Aeson.toJSON evt_line
    , "column"          Aeson..= Aeson.toJSON evt_column
    , "expr_width"      Aeson..= Aeson.toJSON evt_expr_width
    , "event"           Aeson..= Aeson.toJSON evt_event
    , "exception_msg"   Aeson..= Aeson.toJSON evt_exception_msg
    , "expr_before"     Aeson..= Aeson.toJSON (show (pretty evt_before))
    , "expr_after"      Aeson..= Aeson.toJSON (show (pretty evt_after))
    ]

instance Aeson.ToJSON Scope where
  toJSON Scope {..} = Aeson.object
    [ "frame_id"        Aeson..= Aeson.toJSON scp_frame_id
    , "encoded_locals"  Aeson..= Aeson.toJSON scp_encoded_locals
    , "is_highlighted"  Aeson..= Aeson.toJSON scp_is_highlighted
    , "is_parent"       Aeson..= Aeson.toJSON scp_is_parent
    , "func_name"       Aeson..= Aeson.toJSON scp_func_name
    , "is_zombie"       Aeson..= Aeson.toJSON scp_is_zombie
    , "parent_frame_id_list" Aeson..= Aeson.toJSON scp_parent_frame_id_list
    , "unique_hash"     Aeson..= Aeson.toJSON scp_unique_hash
    , "ordered_varnames" Aeson..= Aeson.toJSON scp_ordered_varnames
    ]

instance Aeson.ToJSON Value where
  toJSON (VI _ i) = Aeson.toJSON i
  toJSON (VD _ d) = Aeson.toJSON d
  toJSON (VB _ b) = Aeson.toJSON b
  toJSON (VC _ c) = Aeson.toJSON c
  toJSON (VS _ s) = Aeson.toJSON s
  toJSON _      = Aeson.toJSON ("<<unknown>>" :: String)
