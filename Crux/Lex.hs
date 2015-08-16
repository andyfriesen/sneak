{-# LANGUAGE OverloadedStrings #-}

module Crux.Lex where

import Data.Char
import Crux.Tokens
import qualified Text.Parsec as P
import Data.Text (Text)
import qualified Data.Text as T
import Control.Monad.Identity (Identity)
import Text.Parsec ((<|>))

pos :: P.ParsecT Text u Identity Pos
pos = do
    p <- P.getPosition
    return $ Pos (P.sourceLine p) (P.sourceColumn p)

integerLiteral :: P.ParsecT Text u Identity (Token Pos)
integerLiteral = do
    p <- pos
    digits <- P.many1 P.digit
    return $ Token p $ TInteger $ read digits

stringLiteral :: P.ParsecT Text u Identity (Token Pos)
stringLiteral = do
    p <- pos
    _ <- P.char '"'
    chars <- P.many $ P.satisfy (/= '"')
    _ <- P.char '"'
    return $ Token p $ TString $ T.pack chars

parseIdentifier :: P.ParsecT Text u Identity (Token Pos)
parseIdentifier = do
    p <- pos
    let isIdentifierStart '_' = True
        isIdentifierStart x = isAlpha x

        isIdentifierChar x = isIdentifierStart x || isNumber x

    first <- P.satisfy isIdentifierStart
    rest <- P.many $ P.satisfy isIdentifierChar
    return $ Token p $ TIdentifier $ T.pack (first:rest)

token :: P.ParsecT Text u Identity (Token Pos)
token =
    P.try keyword
    <|> P.try integerLiteral
    <|> P.try stringLiteral
    <|> P.try parseIdentifier
    <|> P.try symbol

keyword :: P.ParsecT Text u Identity (Token Pos)
keyword = P.try $ do
    Token p (TIdentifier i) <- parseIdentifier
    fmap (Token p) $ case i of
        "let" -> return TLet
        "fun" -> return TFun
        "data" -> return TData
        "type" -> return TType
        "match" -> return TMatch
        "if" -> return TIf
        "then" -> return TThen
        "else" -> return TElse
        "return" -> return TReturn
        _ -> fail ""

symbol :: P.ParsecT Text u Identity (Token Pos)
symbol = sym2 '=' '>' TFatRightArrow
     <|> sym2 '-' '>' TRightArrow
     <|> sym ';' TSemicolon
     <|> sym ':' TColon
     <|> sym '.' TDot
     <|> sym ',' TComma
     <|> sym '=' TEqual
     <|> sym '(' TOpenParen
     <|> sym ')' TCloseParen
     <|> sym '{' TOpenBrace
     <|> sym '}' TCloseBrace
     <|> sym '+' TPlus
     <|> sym '-' TMinus
     <|> sym '*' TMultiply
     <|> sym '/' TDivide
  where
    sym ch tok = do
        p <- pos
        _ <- P.char ch
        return (Token p tok)
    sym2 c1 c2 tok = P.try $ do
        p <- pos
        _ <- P.char c1
        _ <- P.char c2
        return (Token p tok)

whitespace :: P.ParsecT Text u Identity ()
whitespace = P.spaces

document :: P.ParsecT Text u Identity [Token Pos]
document = do
    whitespace
    r <- P.many1 $ P.try (whitespace >> token)
    whitespace
    P.eof
    return r

lexSource :: FilePath -> Text -> Either P.ParseError [Token Pos]
lexSource fileName text =
    P.runParser document () fileName text
