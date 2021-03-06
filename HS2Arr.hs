{-# LANGUAGE FlexibleContexts #-}
module HS2Arr where

import Control.Applicative
import Control.Monad
import Control.Monad.Writer

import Data.Map as M
import Data.List (intercalate)
import Data.Functor.Identity

import Language.Haskell.Syntax
import Language.Haskell.Parser
import Language.Haskell.Pretty (prettyPrint)

for :: Functor f => f a -> (a -> b) -> f b
for = flip fmap
for2 a b f = zipWith f a b

unIdent :: HsName -> String
unIdent (HsIdent s) = s

encloseSeperate :: String -> String -> String -> [String] -> String
encloseSeperate _ _ _ [] = []
encloseSeperate b e s l  = b ++ intercalate s l ++ e

indent :: Functor m => WriterT String m a -> WriterT String m a
indent = WriterT
         . (fmap fmap fmap $ \w -> concat $ (\a -> "  " ++ a ++ "\n") <$> lines w)
         . runWriterT


toPyret :: HsModule -> (String, String)
toPyret (HsModule _ (Module mname) _ imports prog) =
  (,) (mname ++ ".arr") $ snd $ runWriter $ do
    mapM_ impor imports
    tell "\n"
    foldM decl M.empty prog

impor :: HsImportDecl -> Writer String ()
impor (HsImportDecl _ (Module mod) True (Just (Module as)) Nothing) =
  tell $ "import \"" ++ mod ++ ".arr\" as " ++ as ++ "\n"
impor _ = return () -- change back to error "qualified imports only" someday.....

specialCon :: HsSpecialCon -> String
specialCon a = case a of
  HsUnitCon    -> "Nothing"
  HsListCon    -> "List"

  HsFunCon     -> "(->)"
  HsTupleCon n -> show n ++ "-tuple"
  HsCons       -> "link"

name (HsIdent  s) = s
name (HsSymbol s) = s

qname :: HsQName -> String
qname (Qual (Module mod) n) = mod ++ "." ++ name n
qname (UnQual n) = name n
qname (Special s) = specialCon s

qtyp :: HsQualType -> String
qtyp (HsQualType [] t) = typ t

typ :: HsType -> String
typ (HsTyVar (HsIdent tvar)) = tvar
typ (HsTyCon tqid)           = qname tqid
typ (HsTyFun t1 t2)          = typ t1 ++ " -> " ++ typ t2
typ app@(HsTyApp _ _) = uncur [] app
  where uncur :: [HsType] -> HsType -> String
        uncur args (HsTyApp a b) = uncur (b : args) a
        uncur args t             = typ t ++ (encloseSeperate "<" ">" ", " $ fmap (uncur []) args)

type TMap = Map String HsType

decl :: TMap -> HsDecl -> Writer String TMap
decl mp declerations = do
  case declerations of
    (HsTypeDecl _ (HsIdent name) [] t) -> do
      tell $ "# s/" ++ name ++"/" ++ typ t ++ "/\n"

    (HsDataDecl _ _ (HsIdent name) params cons _) -> do
      tell $ "data " ++ name
      tell $ encloseSeperate "<" ">" ", " $ fmap unIdent params
      tell ":\n"
      indent $ forM_ cons $ \(HsConDecl _ (HsIdent name) params) -> do
        tell $ "| " ++ name ++ " "
        tell $ encloseSeperate "(" ")" ", " $ for2 params [1..] $
          \(HsUnBangedTy t) i -> "_p-" ++ show i ++ " :: " ++ typ t
        tell "\n"
      tell "end"

    (HsInfixDecl _ _ _ _) -> error "infix"
    (HsDefaultDecl _ types) -> error "default"
    (HsTypeSig _ [HsIdent name] (HsQualType [] t)) -> return ()

    (HsFunBind topcases) -> do
      forM_ topcases $ \(HsMatch _ (HsIdent name) pats expr wheres) -> do
        case pats of
          [] -> do tell $ name ++ " ="
                   when (length wheres == 0) $ tell " block:"
          vars -> do
            tell $ "fun " ++ name ++ " "
            tell $ encloseSeperate "(" "):" ", " $ case M.lookup name mp of
              (Just t) -> for2 vars (splitArgs t) $
                          \var t -> (extract var) ++ " :: " ++ typ t
              Nothing  -> extract <$> vars
        block mp expr wheres "end" $ if length pats == 0 then "" else ";"

      where splitArgs :: HsType -> [HsType]
            splitArgs (HsTyFun t1 t2) = t1 : splitArgs t2
            splitArgs t               = [t]

            extract (HsPVar (HsIdent var)) = var

    (HsPatBind _ pat expr wheres) -> do
      tell "PATBIND ="
      when (length wheres /= 0) $ tell " block:"
      block mp expr wheres "end" ""

  tell "\n"
  return $ case declerations of
    (HsTypeSig _ [HsIdent name] (HsQualType [] t)) -> insert name t mp
    _                                              -> mp


block :: TMap -> HsRhs -> [HsDecl] -> String -> String -> Writer String ()
block mp (HsUnGuardedRhs e) bindings end1 end2 = case bindings of
  [] -> tell " " >> expr e >> tell end2
  _  -> do tell "\n"
           indent $ do foldM_ decl mp bindings
                       expr e
           tell end1

expr :: HsExp -> Writer String ()
expr e = case e of
  (HsVar qn) -> tell $ qname qn
  (HsCon qn) -> tell $ qname qn

  (HsLit lit) -> tell $ prettyPrint lit -- printing literals as Haskell

  (HsInfixApp e1 (HsQVarOp (UnQual (HsSymbol "$"))) e2) -> expr $ case f e1 of
    Nothing     -> HsApp e1 e2
    Just (a, b) -> HsInfixApp a (HsQVarOp (UnQual (HsSymbol "$"))) $ HsApp b e2
    where f (HsInfixApp e1 (HsQVarOp (UnQual (HsSymbol "$"))) e2) = Just (e1, e2)
          f e                                                     = Nothing

  (HsInfixApp e1 op e2) -> do
    expr e1
    tell " "
    tell $ qname $ case op of
      (HsQVarOp qn) -> qn
      (HsQConOp qn) -> qn
    tell " "
    expr e2

  (HsNegApp (HsLit lit)) -> tell $ "-" ++ prettyPrint lit
  (HsNegApp e)           -> tell "(0 - " >> expr e >> tell ")"

  (HsLambda _ pats exp) -> error "lambda"

  (HsLet decls expr) -> do when (length decls /= 0) $ tell "block:"
                           block M.empty (HsUnGuardedRhs e) decls "end" ""

  (HsIf a b c) -> do tell "if "     >> expr a
                     tell ": "      >> expr b
                     tell " else: " >> expr c

  (HsCase (HsExpTypeSig _ outerE t) alts) -> do
    (tell $ "cases (" ++ qtyp t ++ ") ") >> expr outerE >> tell ":\n"
    indent $ forM_ alts $ \(HsAlt _ pat (HsUnGuardedAlt innerE) wheres) -> do
      tell $ "| " ++ "PAT" ++ " =>"
      block M.empty (HsUnGuardedRhs innerE) wheres "\n" "\n"
    tell "end"
  (HsCase _ _) -> error "need case (expr :: type) of"

  (HsTuple es) -> tell $ (show $ length es) ++ "-tuple" ++ (encloseSeperate "(" ")" ", " $ mapToString expr es)
  (HsList es)  -> tell $ encloseSeperate "[" "]" ", " $ mapToString expr es
  (HsParen e)  -> tell "(" >> expr e >> tell ")"

  (HsExpTypeSig _ e t) -> tell "(" >> expr e >> tell " :: " >> (tell $ qtyp t) >> tell ")"

  (HsApp _ _) -> uncur [] e

  where uncur :: [HsExp] -> HsExp -> Writer String ()
        uncur args (HsApp a b) = uncur (b : args) a
        uncur args e           = do expr e
                                    tell $ encloseSeperate "(" ")" ", " $ mapToString (uncur []) args

        mapToString :: (a -> Writer b ()) -> [a] -> [b]
        mapToString f = fmap $ snd . runWriter . f


test :: ParseResult HsModule -> IO ()
test (ParseOk mod) = putStrLn $ snd $ toPyret mod

ast = parseModule <$> readFile "/home/jcericso/git/pyrec/haskell/Pyrec/AST.hs"
ast' = test =<< ast

report = parseModule <$> readFile "/home/jcericso/git/pyrec/haskell/Pyrec/Report.hs"
report' = test =<< report
