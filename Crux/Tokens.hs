{-# LANGUAGE RecordWildCards #-}
module Crux.Tokens where

import Data.Text

data Pos = Pos
    { posLine :: Int
    , posCol :: Int
    }
    deriving (Eq)

instance Show Pos where
    show Pos{..} = (show posLine) ++ ":" ++ (show posCol)

data TokenType
    = TInteger Integer
    | TString Text
    | TIdentifier Text
    -- symbols
    | TOpenBrace
    | TCloseBrace
    | TOpenParen
    | TCloseParen
    | TSemicolon
    | TColon
    | TComma
    | TEqual
    | TDot
    | TRightArrow
    | TFatRightArrow
    | TPlus
    | TMinus
    | TMultiply
    | TDivide
    -- Keywords
    | TFun
    | TLet
    | TData
    | TType
    | TMatch
    | TIf
    | TThen
    | TElse
    | TReturn
    deriving (Show, Eq)

data Token tdata = Token tdata TokenType
      deriving (Show)

{-
instance Eq (Token a) where
    (Token _ lhs) == (Token _ rhs) = lhs == rhs
-}

tokenData :: Token tdata -> tdata
tokenData (Token tdata _) = tdata
