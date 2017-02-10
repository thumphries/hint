module Hint.Eval (
      interpret, interpretIO, as, infer,
      unsafeInterpret,
      eval, parens
) where

import qualified GHC.Exts (unsafeCoerce#)

import Data.Typeable hiding (typeOf)
import qualified Data.Typeable (typeOf)

import Hint.Base
import Hint.Context
import Hint.Parsers
import Hint.Util

import qualified Hint.GHC as GHC

-- | Convenience functions to be used with @interpret@ to provide witnesses.
--   Example:
--
--   * @interpret \"head [True,False]\" (as :: Bool)@
--
--   * @interpret \"head $ map show [True,False]\" infer >>= flip interpret (as :: Bool)@
as, infer :: Typeable a => a
as    = undefined
infer = undefined

-- | Evaluates an expression, given a witness for its monomorphic type.
interpret :: (MonadInterpreter m, Typeable a) => String -> a -> m a
interpret expr wit = unsafeInterpret expr (show $ Data.Typeable.typeOf wit)

-- | Evaluates an IO expression, given a witness for its monomorphic
-- return type.
interpretIO :: (MonadInterpreter m, Typeable a) => String -> a -> m (IO a)
interpretIO expr wit = interpretIOWith expr wit return

-- | Evaluates an IO expression, passing the result thunk to a
-- handler, which may supply custom control flow.
interpretIOWith :: (MonadInterpreter m, Typeable a) => String -> a -> (IO a -> m b) -> m b
interpretIOWith expr wit f =
    do k <- unsafeInterpret expr ("IO " ++ (show $ Data.Typeable.typeOf wit))
       f k

unsafeInterpret :: (MonadInterpreter m) => String -> String -> m a
unsafeInterpret expr type_str =
    do -- First, make sure the expression has no syntax errors,
       -- for this is the only way we have to "intercept" this
       -- kind of errors
       failOnParseError parseExpr expr
       --
       let expr_typesig = concat [parens expr, " :: ", type_str]
       expr_val <- mayFail $ runGhc1 compileExpr expr_typesig
       --
       return (GHC.Exts.unsafeCoerce# expr_val :: a)

-- add a bogus Maybe, in order to use it with mayFail
compileExpr :: GHC.GhcMonad m => String -> m (Maybe GHC.HValue)
compileExpr = fmap Just . GHC.compileExpr

-- | @eval expr@ will evaluate @show expr@.
--  It will succeed only if @expr@ has type t and there is a 'Show'
--  instance for t.
eval :: MonadInterpreter m => String -> m String
eval expr = do in_scope_show   <- supportShow
               in_scope_String <- supportString
               let show_expr = unwords [in_scope_show, parens expr]
               unsafeInterpret show_expr in_scope_String

-- | Conceptually, @parens s = \"(\" ++ s ++ \")\"@, where s is any valid haskell
-- expression. In practice, it is harder than this.
-- Observe that if @s@ ends with a trailing comment, then @parens s@ would
-- be a malformed expression. The straightforward solution for this is to
-- put the closing parenthesis in a different line. However, now we are
-- messing with the layout rules and we don't know where @s@ is going to
-- be used!
-- Solution: @parens s = \"(let {foo =\n\" ++ s ++ \"\\n ;} in foo)\"@ where @foo@ does not occur in @s@
parens :: String -> String
parens s = concat ["(let {", foo, " =\n", s, "\n",
                   "                     ;} in ", foo, ")"]
    where foo = safeBndFor s
