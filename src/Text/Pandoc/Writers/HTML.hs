{-# LANGUAGE OverloadedStrings, CPP, ViewPatterns, ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-deprecations #-}
{-
Copyright (C) 2006-2014 John MacFarlane <jgm@berkeley.edu>
Copyright (C) 2014 Tim T.Y. Lin <timtylin@gmail.com>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Writers.HTML
   Copyright   : Copyright (C) 2006-2014 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to HTML.
-}
module Text.Pandoc.Writers.HTML ( writeHtml , writeHtmlString ) where
import Text.Pandoc.Definition
import Text.Pandoc.Shared
import Text.Pandoc.Writers.Shared
import Text.Pandoc.Options
import Text.Pandoc.Templates
import Text.Pandoc.Readers.TeXMath
import Text.Pandoc.Slides
import Text.Pandoc.Highlighting ( highlight, styleToCss,
                                  formatHtmlInline, formatHtmlBlock )
import Text.Pandoc.XML (fromEntities, escapeStringForXML)
import Text.Pandoc.Scholarly
import Network.URI ( parseURIReference, URI(..), unEscapeString )
import Network.HTTP ( urlEncode )
import Numeric ( showHex )
import Data.Char ( ord, toLower )
import Data.List ( isPrefixOf, intersperse, intercalate )
import Data.String ( fromString )
import Data.Maybe ( catMaybes, fromMaybe, fromJust, isJust, isNothing )
import Control.Monad.State
import Text.Blaze.Html hiding(contents)
#if MIN_VERSION_blaze_markup(0,6,3)
#else
import Text.Blaze.Internal(preEscapedString)
#endif
#if MIN_VERSION_blaze_html(0,5,1)
import qualified Text.Blaze.XHtml5 as H5
#else
import qualified Text.Blaze.Html5 as H5
#endif
import qualified Text.Blaze.XHtml1.Transitional as H
import qualified Text.Blaze.XHtml1.Transitional.Attributes as A
import Text.Blaze.Renderer.String (renderHtml)
import Text.TeXMath
import Text.XML.Light.Output
import Text.XML.Light (unode, elChildren, unqual)
import qualified Text.XML.Light as XML
import System.FilePath (takeExtension)
import Data.Monoid
import Data.Aeson (Value)
import Control.Applicative ((<$>))

data WriterState = WriterState
    { stNotes            :: [Html]  -- ^ List of notes
    , stMath             :: Bool    -- ^ Math is used in document
    , stQuotes           :: Bool    -- ^ <q> tag is used
    , stHighlighting     :: Bool    -- ^ Syntax highlighting is used
    , stSecNum           :: [Int]   -- ^ Number of current section
    , stMathIds          :: [String]
    , stLastHeight       :: Maybe String  -- last img height value
    , stLastWidth        :: Maybe String  -- last img width value
    , stElement          :: Bool    -- ^ Processing an Element
    }

defaultWriterState :: WriterState
defaultWriterState = WriterState {stNotes= [], stMath = False, stQuotes = False,
                                  stHighlighting = False, stSecNum = [],
                                  stMathIds = [], stLastHeight = Nothing,
                                  stLastWidth = Nothing,
                                  stElement = False}

-- Helpers to render HTML with the appropriate function.

strToHtml :: String -> Html
strToHtml ('\'':xs) = preEscapedString "\'" `mappend` strToHtml xs
strToHtml xs@(_:_)  = case break (=='\'') xs of
                           (_ ,[]) -> toHtml xs
                           (ys,zs) -> toHtml ys `mappend` strToHtml zs
strToHtml [] = ""

-- | Hard linebreak.
nl :: WriterOptions -> Html
nl opts = if writerWrapText opts
             then preEscapedString "\n"
             else mempty

-- | Convert Pandoc document to Html string.
writeHtmlString :: WriterOptions -> Pandoc -> String
writeHtmlString opts d =
  let (body, context) = evalState (pandocToHtml opts d) defaultWriterState
  in  if writerStandalone opts
         then inTemplate opts context body
         else renderHtml body

-- | Convert Pandoc document to Html structure.
writeHtml :: WriterOptions -> Pandoc -> Html
writeHtml opts d =
  let (body, context) = evalState (pandocToHtml opts d) defaultWriterState
  in  if writerStandalone opts
         then inTemplate opts context body
         else body

-- result is (title, authors, date, toc, body, new variables)
pandocToHtml :: WriterOptions
             -> Pandoc
             -> State WriterState (Html, Value)
pandocToHtml opts (Pandoc meta blocks) = do
  -- make sure title is set for abstract section
  metadata <- metaToJSON opts
              (fmap renderHtml . blockListToHtml opts)
              (fmap renderHtml . inlineListToHtml opts)
              meta
  initSt <- get
  -- these ids will be handled by MathJax if in Scholarly Markdown
  let mathIds = extractMetaStringList $ lookupMeta "identifiersForMath" meta
  put initSt{ stMathIds = mathIds }
  let stringifyHTML = escapeStringForXML . stringify
  let authsMeta = map stringifyHTML $ docAuthors meta
  let dateMeta  = stringifyHTML $ docDate meta
  let slideLevel = fromMaybe (getSlideLevel blocks) $ writerSlideLevel opts
  let sects = hierarchicalize $
              if writerSlideVariant opts == NoSlides
                 then blocks
                 else prepSlides slideLevel blocks
  toc <- if writerTableOfContents opts
            then tableOfContents opts sects
            else return Nothing
  blocks' <- liftM (mconcat . intersperse (nl opts)) $
                 mapM (elementToHtml slideLevel opts) sects
  st <- get
  let notes = reverse (stNotes st)
  let thebody = blocks' >> footnoteSection opts notes
  let mathDefs = lookupMeta "latexMacrosForMath" meta
  let  math = if stMath st
                then case writerHTMLMathMethod opts of
                           LaTeXMathML (Just url) ->
                              H.script ! A.src (toValue url)
                                       ! A.type_ "text/javascript"
                                       $ mempty
                           MathML (Just url) ->
                              H.script ! A.src (toValue url)
                                       ! A.type_ "text/javascript"
                                       $ mempty
                           MathJax url ->
                              if url == "" then mempty
                                 else H.script ! A.src (toValue url)
                                               ! A.type_ "text/javascript"
                              $ case writerSlideVariant opts of
                                     SlideousSlides ->
                                        preEscapedString
                                        "MathJax.Hub.Queue([\"Typeset\",MathJax.Hub]);"
                                     _ -> mempty
                           JsMath (Just url) ->
                              H.script ! A.src (toValue url)
                                       ! A.type_ "text/javascript"
                                       $ mempty
                           KaTeX js css ->
                              (H.script ! A.src (toValue js) $ mempty) <>
                              (H.link ! A.rel "stylesheet" ! A.href (toValue css)) <>
                              (H.script ! A.type_ "text/javascript" $ toHtml renderKaTeX)
                           _ -> case lookup "mathml-script" (writerVariables opts) of
                                      Just s | not (writerHtml5 opts) ->
                                        H.script ! A.type_ "text/javascript"
                                           $ preEscapedString
                                            ("/*<![CDATA[*/\n" ++ s ++ "/*]]>*/\n")
                                             | otherwise -> mempty
                                      Nothing -> mempty
                else mempty
  let context =   (if stHighlighting st
                      then defField "highlighting-css"
                             (styleToCss $ writerHighlightStyle opts)
                      else id) $
                  (if stMath st
                      then defField "math" (renderHtml math)
                      else id) $
                  (if isJust mathDefs
                      then defField "math-macros"
                             (extractMetaString $ fromJust mathDefs)
                      else id) $
                  defField "quotes" (stQuotes st) $
                  maybe id (defField "toc" . renderHtml) toc $
                  defField "author-meta" authsMeta $
                  maybe id (defField "date-meta") (normalizeDate dateMeta) $
                  (if (isJust $ lookupMeta "abstract" meta)
                      && (isNothing $ lookupMeta "abstract-title" meta)
                      then defField "abstract-title" ("Abstract" :: String)
                      else id) $
                  defField "pagetitle" (stringifyHTML $ docTitle meta) $
                  defField "idprefix" (writerIdentifierPrefix opts) $
                  -- these should maybe be set in pandoc.hs
                  defField "slidy-url"
                    ("http://www.w3.org/Talks/Tools/Slidy2" :: String) $
                  defField "slideous-url" ("slideous" :: String) $
                  defField "revealjs-url" ("reveal.js" :: String) $
                  defField "s5-url" ("s5/default" :: String) $
                  defField "html5" (writerHtml5 opts) $
                  metadata
  return (thebody, context)

inTemplate :: TemplateTarget a
           => WriterOptions
           -> Value
           -> Html
           -> a
inTemplate opts context body = renderTemplate' (writerTemplate opts)
                             $ defField "body" (renderHtml body) context

-- | Like Text.XHtml's identifier, but adds the writerIdentifierPrefix
prefixedId :: WriterOptions -> String -> Attribute
prefixedId opts s =
  case s of
    ""       -> mempty
    _        -> A.id $ toValue $ writerIdentifierPrefix opts ++ s

toList :: (Html -> Html) -> WriterOptions -> ([Html] -> Html)
toList listop opts items = do
    if (writerIncremental opts)
       then if (writerSlideVariant opts /= RevealJsSlides)
               then (listop $ mconcat items) ! A.class_ "incremental"
               else listop $ mconcat $ map (! A.class_ "fragment") items
       else listop $ mconcat items

unordList :: WriterOptions -> [Html] -> Html
unordList opts = toList H.ul opts . toListItems opts

ordList :: WriterOptions -> [Html] -> Html
ordList opts = toList H.ol opts . toListItems opts

defList :: WriterOptions -> [Html] -> Html
defList opts items = toList H.dl opts (items ++ [nl opts])

-- | Construct table of contents from list of elements.
tableOfContents :: WriterOptions -> [Element] -> State WriterState (Maybe Html)
tableOfContents _ [] = return Nothing
tableOfContents opts sects = do
  let opts'        = opts { writerIgnoreNotes = True }
  contents  <- mapM (elementToListItem opts') sects
  let tocList = catMaybes contents
  return $ if null tocList
              then Nothing
              else Just $ unordList opts tocList

-- | Convert section number to string
showSecNum :: [Int] -> String
showSecNum = concat . intersperse "." . map show

-- | Converts an Element to a list item for a table of contents,
-- retrieving the appropriate identifier from state.
elementToListItem :: WriterOptions -> Element -> State WriterState (Maybe Html)
-- Don't include the empty headers created in slide shows
-- shows when an hrule is used to separate slides without a new title:
elementToListItem _ (Sec _ _ _ [Str "\0"] _) = return Nothing
elementToListItem opts (Sec lev num (id',classes,_) headerText subsecs)
  | lev <= writerTOCDepth opts = do
  let num' = zipWith (+) num (writerNumberOffset opts ++ repeat 0)
  let sectnum = if writerNumberSections opts && not (null num) &&
                   "unnumbered" `notElem` classes
                   then (H.span ! A.class_ "toc-section-number"
                        $ toHtml $ showSecNum num') >> preEscapedString " "
                   else mempty
  txt <- liftM (sectnum >>) $ inlineListToHtml opts headerText
  subHeads <- mapM (elementToListItem opts) subsecs >>= return . catMaybes
  let subList = if null subHeads
                   then mempty
                   else unordList opts subHeads
  -- in reveal.js, we need #/apples, not #apples:
  let revealSlash = ['/' | writerSlideVariant opts == RevealJsSlides]
  return $ Just
         $ if null id'
              then (H.a $ toHtml txt) >> subList
              else (H.a ! A.href (toValue $ "#" ++ revealSlash ++
                    writerIdentifierPrefix opts ++ id')
                       $ toHtml txt) >> subList
elementToListItem _ _ = return Nothing

-- | Convert an Element to Html.
elementToHtml :: Int -> WriterOptions -> Element -> State WriterState Html
elementToHtml _slideLevel opts (Blk block) = blockToHtml opts block
elementToHtml slideLevel opts (Sec level num (id',classes,keyvals) title' elements) = do
  let slide = writerSlideVariant opts /= NoSlides && level <= slideLevel
  let num' = zipWith (+) num (writerNumberOffset opts ++ repeat 0)
  modify $ \st -> st{stSecNum = num'}  -- update section number
  -- always use level 1 for slide titles
  let level' = if slide then 1 else level
  let titleSlide = slide && level < slideLevel
  header' <- if title' == [Str "\0"]  -- marker for hrule
                then return mempty
                else do
                  modify (\st -> st{ stElement = True})
                  res <- blockToHtml opts
                           (Header level' (id',classes,keyvals) title')
                  modify (\st -> st{ stElement = False})
                  return res

  let isSec (Sec _ _ _ _ _) = True
      isSec (Blk _)         = False
  let isPause (Blk x) = x == Para [Str ".",Space,Str ".",Space,Str "."]
      isPause _       = False
  let fragmentClass = case writerSlideVariant opts of
                           RevealJsSlides  -> "fragment"
                           _               -> "incremental"
  let inDiv xs = Blk (RawBlock (Format "html") ("<div class=\""
                       ++ fragmentClass ++ "\">")) :
                   (xs ++ [Blk (RawBlock (Format "html") "</div>")])
  innerContents <- mapM (elementToHtml slideLevel opts)
                   $ if titleSlide
                        -- title slides have no content of their own
                        then filter isSec elements
                        else if slide
                                then case splitBy isPause elements of
                                          []     -> []
                                          (x:xs) -> x ++ concatMap inDiv xs
                                else elements
  let inNl x = mconcat $ nl opts : intersperse (nl opts) x ++ [nl opts]
  let classes' = ["titleslide" | titleSlide] ++ ["slide" | slide] ++
                  ["section" | (slide || writerSectionDivs opts) &&
                               not (writerHtml5 opts) ] ++
                  ["level" ++ show level | slide || writerSectionDivs opts ]
                  ++ classes
  let secttag  = if writerHtml5 opts
                    then H5.section
                    else H.div
  let attr = (id',classes',keyvals)
  return $ if titleSlide
              then (if writerSlideVariant opts == RevealJsSlides
                       then H5.section
                       else id) $ mconcat $
                       (addAttrs opts attr $ secttag $ header') : innerContents
              else if writerSectionDivs opts || slide
                   then addAttrs opts attr
                        $ secttag $ inNl $ header' : innerContents
                   else mconcat $ intersperse (nl opts)
                        $ addAttrs opts attr header' : innerContents

-- | Convert list of Note blocks to a footnote <div>.
-- Assumes notes are sorted.
footnoteSection :: WriterOptions -> [Html] -> Html
footnoteSection opts notes =
  if null notes
     then mempty
     else nl opts >> (container
          $ nl opts >> hrtag >> nl opts >>
            H.ol (mconcat notes >> nl opts) >> nl opts)
   where container x = if writerHtml5 opts
                          then H5.section ! A.class_ "footnotes" $ x
                          else if writerSlideVariant opts /= NoSlides
                               then H.div ! A.class_ "footnotes slide" $ x
                               else H.div ! A.class_ "footnotes" $ x
         hrtag = if writerHtml5 opts then H5.hr else H.hr

-- | Parse a mailto link; return Just (name, domain) or Nothing.
parseMailto :: String -> Maybe (String, String)
parseMailto s = do
  case break (==':') s of
       (xs,':':addr) | map toLower xs == "mailto" -> do
         let (name', rest) = span (/='@') addr
         let domain = drop 1 rest
         return (name', domain)
       _ -> fail "not a mailto: URL"

-- | Obfuscate a "mailto:" link.
obfuscateLink :: WriterOptions -> Html -> String -> Html
obfuscateLink opts txt s | writerEmailObfuscation opts == NoObfuscation =
  H.a ! A.href (toValue s) $ txt
obfuscateLink opts (renderHtml -> txt) s =
  let meth = writerEmailObfuscation opts
      s' = map toLower (take 7 s) ++ drop 7 s
  in  case parseMailto s' of
        (Just (name', domain)) ->
          let domain'  = substitute "." " dot " domain
              at'      = obfuscateChar '@'
              (linkText, altText) =
                 if txt == drop 7 s' -- autolink
                    then ("e", name' ++ " at " ++ domain')
                    else ("'" ++ txt ++ "'", txt ++ " (" ++ name' ++ " at " ++
                          domain' ++ ")")
          in  case meth of
                ReferenceObfuscation ->
                     -- need to use preEscapedString or &'s are escaped to &amp; in URL
                     preEscapedString $ "<a href=\"" ++ (obfuscateString s')
                     ++ "\" class=\"email\">" ++ (obfuscateString txt) ++ "</a>"
                JavascriptObfuscation ->
                     (H.script ! A.type_ "text/javascript" $
                     preEscapedString ("\n<!--\nh='" ++
                     obfuscateString domain ++ "';a='" ++ at' ++ "';n='" ++
                     obfuscateString name' ++ "';e=n+a+h;\n" ++
                     "document.write('<a h'+'ref'+'=\"ma'+'ilto'+':'+e+'\" clas'+'s=\"em' + 'ail\">'+" ++
                     linkText  ++ "+'<\\/'+'a'+'>');\n// -->\n")) >>
                     H.noscript (preEscapedString $ obfuscateString altText)
                _ -> error $ "Unknown obfuscation method: " ++ show meth
        _ -> H.a ! A.href (toValue s) $ toHtml txt  -- malformed email

-- | Obfuscate character as entity.
obfuscateChar :: Char -> String
obfuscateChar char =
  let num    = ord char
      numstr = if even num then show num else "x" ++ showHex num ""
  in  "&#" ++ numstr ++ ";"

-- | Obfuscate string using entities.
obfuscateString :: String -> String
obfuscateString = concatMap obfuscateChar . fromEntities

addAttrs :: WriterOptions -> Attr -> Html -> Html
addAttrs opts attr h = foldl (!) h (attrsToHtml opts attr)

attrsToHtml :: WriterOptions -> Attr -> [Attribute]
attrsToHtml opts (id',classes',keyvals) =
  [prefixedId opts id' | not (null id')] ++
  [A.class_ (toValue $ unwords classes') | not (null classes')] ++
  map (\(x,y) -> customAttribute (fromString x) (toValue y)) keyvals

imageExts :: [String]
imageExts = [ "art", "bmp", "cdr", "cdt", "cpt", "cr2", "crw", "djvu", "erf",
              "gif", "ico", "ief", "jng", "jpg", "jpeg", "nef", "orf", "pat", "pbm",
              "pcx", "pdf", "pgm", "png", "pnm", "ppm", "psd", "ras", "rgb", "svg",
              "tiff", "wbmp", "xbm", "xpm", "xwd" ]

treatAsImage :: FilePath -> Bool
treatAsImage fp =
  let path = case uriPath `fmap` parseURIReference fp of
                  Nothing -> fp
                  Just up -> up
      ext  = map toLower $ drop 1 $ takeExtension path
  in  null ext || ext `elem` imageExts

setImageWidthFromHistory :: Inline -> State WriterState Inline
setImageWidthFromHistory (Image attr b c) = do
  let attrWidth = fromMaybe "" $ lookupKey "width" attr
  st <- get
  let lastWidth = fromMaybe "" $ stLastWidth st
  let replaceWidth = attrWidth == "same" || attrWidth == "^"
  let currWidth = if replaceWidth
                     then lastWidth
                     else attrWidth
  when (not $ null currWidth) $ put st { stLastWidth = Just currWidth }
  let attr' = insertReplaceKeyVal ("width",currWidth) attr
  return $ Image attr' b c
setImageWidthFromHistory x = return x

-- | Convert Pandoc block element to HTML.
blockToHtml :: WriterOptions -> Block -> State WriterState Html
blockToHtml _ Null = return mempty
blockToHtml opts (Plain lst) = inlineListToHtml opts lst
-- title beginning with fig: indicates that the image is a figure
blockToHtml opts (Para [Image attr txt (s,'f':'i':'g':':':tit)]) =
  imageGridToHtml opts attr [ImageGrid [[Image attr [] (s,tit)]]] noPrepContent txt
blockToHtml opts (Para lst) = do
  contents <- inlineListToHtml opts lst
  return $ H.p contents
blockToHtml opts (Div attr@(_,classes,_) bs) = do
  contents <- blockListToHtml opts bs
  let contents' = nl opts >> contents >> nl opts
  return $
     if "notes" `elem` classes
        then let opts' = opts{ writerIncremental = False } in
             -- we don't want incremental output inside speaker notes
             case writerSlideVariant opts of
                  RevealJsSlides -> addAttrs opts' attr $ H5.aside $ contents'
                  NoSlides       -> addAttrs opts' attr $ H.div $ contents'
                  _              -> mempty
        else addAttrs opts attr $ H.div $ contents'
blockToHtml _ (RawBlock f str)
  | f == Format "html" = return $ preEscapedString str
  | otherwise          = return mempty
blockToHtml opts (HorizontalRule) = return $ if writerHtml5 opts then H5.hr else H.hr
blockToHtml opts (CodeBlock (id',classes,keyvals) rawCode) = do
  let tolhs = isEnabled Ext_literate_haskell opts &&
                any (\c -> map toLower c == "haskell") classes &&
                any (\c -> map toLower c == "literate") classes
      classes' = if tolhs
                    then map (\c -> if map toLower c == "haskell"
                                       then "literatehaskell"
                                       else c) classes
                    else classes
      adjCode  = if tolhs
                    then unlines . map ("> " ++) . lines $ rawCode
                    else rawCode
      hlCode   = if writerHighlight opts -- check highlighting options
                    then highlight formatHtmlBlock (id',classes',keyvals) adjCode
                    else Nothing
  case hlCode of
         Nothing -> return $ addAttrs opts (id',classes,keyvals)
                           $ H.pre $ H.code $ toHtml adjCode
         Just  h -> modify (\st -> st{ stHighlighting = True }) >>
                    return (addAttrs opts (id',[],keyvals) h)
blockToHtml opts (BlockQuote blocks) =
  -- in S5, treat list in blockquote specially
  -- if default is incremental, make it nonincremental;
  -- otherwise incremental
  if writerSlideVariant opts /= NoSlides
     then let inc = not (writerIncremental opts) in
          case blocks of
             [BulletList lst]  -> blockToHtml (opts {writerIncremental = inc})
                                  (BulletList lst)
             [OrderedList attribs lst] ->
                                  blockToHtml (opts {writerIncremental = inc})
                                  (OrderedList attribs lst)
             [DefinitionList lst] ->
                                  blockToHtml (opts {writerIncremental = inc})
                                  (DefinitionList lst)
             _                 -> do contents <- blockListToHtml opts blocks
                                     return $ H.blockquote
                                            $ nl opts >> contents >> nl opts
     else do
       contents <- blockListToHtml opts blocks
       return $ H.blockquote $ nl opts >> contents >> nl opts
blockToHtml opts (Header level attr@(_,classes,_) lst) = do
  contents <- inlineListToHtml opts lst
  secnum <- liftM stSecNum get
  let contents' = if writerNumberSections opts && not (null secnum)
                     && "unnumbered" `notElem` classes
                     then (H.span ! A.class_ "header-section-number" $ toHtml
                          $ showSecNum secnum) >> strToHtml " " >> contents
                     else contents
  inElement <- gets stElement
  return $ (if inElement then id else addAttrs opts attr)
         $ case level of
              1 -> H.h1 contents'
              2 -> H.h2 contents'
              3 -> H.h3 contents'
              4 -> H.h4 contents'
              5 -> H.h5 contents'
              6 -> H.h6 contents'
              _ -> H.p contents'
blockToHtml opts (BulletList lst) = do
  contents <- mapM (blockListToHtml opts) lst
  return $ unordList opts contents
blockToHtml opts (OrderedList (startnum, numstyle, _) lst) = do
  contents <- mapM (blockListToHtml opts) lst
  let numstyle' = case numstyle of
                       Example -> "decimal"
                       _       -> camelCaseToHyphenated $ show numstyle
  let attribs = (if startnum /= 1
                   then [A.start $ toValue startnum]
                   else []) ++
                (if numstyle /= DefaultStyle
                   then if writerHtml5 opts
                           then [A.type_ $
                                 case numstyle of
                                      Decimal    -> "1"
                                      LowerAlpha -> "a"
                                      UpperAlpha -> "A"
                                      LowerRoman -> "i"
                                      UpperRoman -> "I"
                                      _          -> "1"]
                           else [A.style $ toValue $ "list-style-type: " ++
                                   numstyle']
                   else [])
  return $ foldl (!) (ordList opts contents) attribs
blockToHtml opts (DefinitionList lst) = do
  contents <- mapM (\(term, defs) ->
                  do term' <- if null term
                                 then return mempty
                                 else liftM H.dt $ inlineListToHtml opts term
                     defs' <- mapM ((liftM (\x -> H.dd $ (x >> nl opts))) .
                                    blockListToHtml opts) defs
                     return $ mconcat $ nl opts : term' : nl opts :
                                        intersperse (nl opts) defs') lst
  return $ defList opts contents
blockToHtml opts (Table capt aligns widths headers rows') = do
  captionDoc <- if null capt
                   then return mempty
                   else do
                     cs <- inlineListToHtml opts capt
                     return $ H.caption cs >> nl opts
  let percent w = show (truncate (100*w) :: Integer) ++ "%"
  let coltags = if all (== 0.0) widths
                   then mempty
                   else do
                     H.colgroup $ do
                       nl opts
                       mapM_ (\w -> do
                            if writerHtml5 opts
                               then H.col ! A.style (toValue $ "width: " ++
                                                      percent w)
                               else H.col ! A.width (toValue $ percent w)
                            nl opts) widths
                     nl opts
  head' <- if all null headers
              then return mempty
              else do
                contents <- tableRowToHtml opts aligns 0 headers
                return $ H.thead (nl opts >> contents) >> nl opts
  body' <- liftM (\x -> H.tbody (nl opts >> mconcat x)) $
               zipWithM (tableRowToHtml opts aligns) [1..] rows'
  return $ H.table $ nl opts >> captionDoc >> coltags >> head' >>
                   body' >> nl opts
blockToHtml opts (Figure figType attr content pc caption) =
  figureToHtml figType opts attr content pc caption
blockToHtml _ (ImageGrid _) = return mempty
blockToHtml _ (Statement _ _) = return mempty
blockToHtml _ (Proof _ _) = return mempty

tableRowToHtml :: WriterOptions
               -> [Alignment]
               -> Int
               -> [[Block]]
               -> State WriterState Html
tableRowToHtml opts aligns rownum cols' = do
  let mkcell = if rownum == 0 then H.th else H.td
  let rowclass = case rownum of
                      0                  -> "header"
                      x | x `rem` 2 == 1 -> "odd"
                      _                  -> "even"
  cols'' <- sequence $ zipWith
            (\alignment item -> tableItemToHtml opts mkcell alignment item)
            aligns cols'
  return $ (H.tr ! A.class_ rowclass $ nl opts >> mconcat cols'')
          >> nl opts

alignmentToString :: Alignment -> [Char]
alignmentToString alignment = case alignment of
                                 AlignLeft    -> "left"
                                 AlignRight   -> "right"
                                 AlignCenter  -> "center"
                                 AlignDefault -> "left"

tableItemToHtml :: WriterOptions
                -> (Html -> Html)
                -> Alignment
                -> [Block]
                -> State WriterState Html
tableItemToHtml opts tag' align' item = do
  contents <- blockListToHtml opts item
  let alignStr = alignmentToString align'
  let attribs = if writerHtml5 opts
                   then A.style (toValue $ "text-align: " ++ alignStr ++ ";")
                   else A.align (toValue alignStr)
  return $ (tag' ! attribs $ contents) >> nl opts

toListItems :: WriterOptions -> [Html] -> [Html]
toListItems opts items = map (toListItem opts) items ++ [nl opts]

toListItem :: WriterOptions -> Html -> Html
toListItem opts item = nl opts >> H.li item

blockListToHtml :: WriterOptions -> [Block] -> State WriterState Html
blockListToHtml opts lst =
  fmap (mconcat . intersperse (nl opts)) $ mapM (blockToHtml opts) lst

-- | Convert list of Pandoc inline elements to HTML.
inlineListToHtml :: WriterOptions -> [Inline] -> State WriterState Html
inlineListToHtml opts lst =
  mapM (inlineToHtml opts) (prependNbsp lst) >>= return . mconcat
  -- ## prependNbsp
  -- usually numbered cross-references should be prepended with
  -- a nonbreaking space, so we do that, except when a bunch of
  -- them appears in a comma-separated list
  where prependNbsp [] = []
        prependNbsp (Str "," : Space : NumRef a as : xs) =
          Str "," : Space : NumRef a as : prependNbsp xs
        prependNbsp (Str a : Space : NumRef b bs : xs) =
          Str (a ++ "\160") : NumRef b bs : prependNbsp xs
        prependNbsp (x:xs) = x : prependNbsp xs

-- | Annotates a MathML expression with the tex source
annotateMML :: XML.Element -> String -> XML.Element
annotateMML e tex = math (unode "semantics" [cs, unode "annotation" (annotAttrs, tex)])
  where
    cs = case elChildren e of
          [] -> unode "mrow" ()
          [x] -> x
          xs -> unode "mrow" xs
    math childs = XML.Element q as [XML.Elem childs] l
      where
        (XML.Element q as _ l) = e
    annotAttrs = [XML.Attr (unqual "encoding") "application/x-tex"]


-- | Convert Pandoc inline element to HTML.
inlineToHtml :: WriterOptions -> Inline -> State WriterState Html
inlineToHtml opts inline =
  case inline of
    (Str str)        -> return $ strToHtml str
    (Space)          -> return $ strToHtml " "
    (LineBreak)      -> return $ if writerHtml5 opts then H5.br else H.br
    (Span (id',classes,kvs) ils)
                     -> inlineListToHtml opts ils >>=
                           return . addAttrs opts attr' . H.span
                        where attr' = (id',classes',kvs')
                              classes' = filter (`notElem` ["csl-no-emph",
                                              "csl-no-strong",
                                              "csl-no-smallcaps"]) classes
                              kvs' = if null styles
                                        then kvs
                                        else (("style", concat styles) : kvs)
                              styles = ["font-style:normal;"
                                         | "csl-no-emph" `elem` classes]
                                    ++ ["font-weight:normal;"
                                         | "csl-no-strong" `elem` classes]
                                    ++ ["font-variant:normal;"
                                         | "csl-no-smallcaps" `elem` classes]
    (Emph lst)       -> inlineListToHtml opts lst >>= return . H.em
    (Strong lst)     -> inlineListToHtml opts lst >>= return . H.strong
    (Code attr str)  -> case hlCode of
                             Nothing -> return
                                        $ addAttrs opts attr
                                        $ H.code $ strToHtml str
                             Just  h -> do
                               modify $ \st -> st{ stHighlighting = True }
                               return $ addAttrs opts (id',[],keyvals) h
                        where (id',_,keyvals) = attr
                              hlCode = if writerHighlight opts
                                          then highlight formatHtmlInline attr str
                                          else Nothing
    (Strikeout lst)  -> inlineListToHtml opts lst >>=
                        return . H.del
    (SmallCaps lst)   -> inlineListToHtml opts lst >>=
                         return . (H.span ! A.style "font-variant: small-caps;")
    (Superscript lst) -> inlineListToHtml opts lst >>= return . H.sup
    (Subscript lst)   -> inlineListToHtml opts lst >>= return . H.sub
    (Quoted quoteType lst) ->
                        let (leftQuote, rightQuote) = case quoteType of
                              SingleQuote -> (strToHtml "‘",
                                              strToHtml "’")
                              DoubleQuote -> (strToHtml "“",
                                              strToHtml "”")
                        in  if writerHtmlQTags opts
                               then do
                                 modify $ \st -> st{ stQuotes = True }
                                 H.q `fmap` inlineListToHtml opts lst
                               else (\x -> leftQuote >> x >> rightQuote)
                                    `fmap` inlineListToHtml opts lst
    (Math t str) -> do
      modify (\st -> st {stMath = True})
      let mathClass = toValue $ ("math " :: String) ++
                      if t == InlineMath then "inline" else "display"
      case writerHTMLMathMethod opts of
           LaTeXMathML _ ->
              -- putting LaTeXMathML in container with class "LaTeX" prevents
              -- non-math elements on the page from being treated as math by
              -- the javascript
              return $ H.span ! A.class_ "LaTeX" $
                     case t of
                       InlineMath  -> toHtml ("$" ++ str ++ "$")
                       DisplayMath _ -> toHtml ("$$" ++ str ++ "$$")
           JsMath _ -> do
              let m = preEscapedString str
              return $ case t of
                       InlineMath -> H.span ! A.class_ mathClass $ m
                       DisplayMath _ -> H.div ! A.class_ mathClass $ m
           WebTeX url -> do
              let imtag = if writerHtml5 opts then H5.img else H.img
              let m = imtag ! A.style "vertical-align:middle"
                            ! A.src (toValue $ url ++ urlEncode str)
                            ! A.alt (toValue str)
                            ! A.title (toValue str)
              let brtag = if writerHtml5 opts then H5.br else H.br
              return $ case t of
                        InlineMath  -> m
                        DisplayMath _ -> brtag >> m >> brtag
           GladTeX ->
              return $ case t of
                         InlineMath -> preEscapedString $ "<EQ ENV=\"math\">" ++ str ++ "</EQ>"
                         DisplayMath _ -> preEscapedString $ "<EQ ENV=\"displaymath\">" ++ str ++ "</EQ>"
           MathML _ -> do
              let dt = if t == InlineMath
                          then DisplayInline
                          else DisplayBlock
              let conf = useShortEmptyTags (const False)
                           defaultConfigPP
              case writeMathML dt <$> readTeX str of
                    Right r  -> return $ preEscapedString $
                        ppcElement conf (annotateMML r str)
                    Left _   -> inlineListToHtml opts
                        (texMathToInlines t str) >>=
                        return .  (H.span ! A.class_ mathClass)
           MathJax _ -> if writerScholarly opts
                           then return $ mathToMathJax opts t str
                           else return $ H.span ! A.class_ mathClass $ toHtml $
                                  case t of
                                    InlineMath  -> "\\(" ++ str ++ "\\)"
                                    DisplayMath _ -> "\\[" ++ str ++ "\\]"
           KaTeX _ _ -> return $ H.span ! A.class_ mathClass $
              toHtml (case t of
                        InlineMath -> str
                        DisplayMath _ -> "\\displaystyle " ++ str)
           PlainMath -> do
              x <- inlineListToHtml opts (texMathToInlines t str)
              let m = H.span ! A.class_ mathClass $ x
              let brtag = if writerHtml5 opts then H5.br else H.br
              return  $ case t of
                         InlineMath  -> m
                         DisplayMath _ -> brtag >> m >> brtag 
    (RawInline f str)
      | f == Format "latex" ->
                          case writerHTMLMathMethod opts of
                               LaTeXMathML _ -> do modify (\st -> st {stMath = True})
                                                   return $ toHtml str
                               _             -> return mempty
      | f == Format "html" -> return $ preEscapedString str
      | otherwise          -> return mempty
    (Link txt (s,_)) | "mailto:" `isPrefixOf` s -> do
                        linkText <- inlineListToHtml opts txt
                        return $ obfuscateLink opts linkText s
    (Link txt (s,tit)) -> do
                        linkText <- inlineListToHtml opts txt
                        let s' = case s of
                                      '#':xs | writerSlideVariant opts ==
                                            RevealJsSlides -> '#':'/':xs
                                      _ -> s
                        let link = H.a ! A.href (toValue s') $ linkText
                        let link' = if txt == [Str (unEscapeString s)]
                                       then link ! A.class_ "uri"
                                       else link
                        return $ if null tit
                                    then link'
                                    else link' ! A.title (toValue tit)
    (Image attr txt (s,tit)) | treatAsImage s -> do
                        let attributes = [A.src $ toValue s] ++
                                         [A.title $ toValue tit | not $ null tit] ++
                                         [A.alt $ toValue $ stringify txt]
                        let tag = if writerHtml5 opts then H5.img else H.img
                        return $ addAttrs opts attr $ foldl (!) tag attributes
                        -- note:  null title included, as in Markdown.pl
    (Image attr _ (s,tit)) -> do
                        let attributes = [A.src $ toValue s] ++
                                         [A.title $ toValue tit | not $ null tit]
                        return $ addAttrs opts attr $ foldl (!) H5.embed attributes
                        -- note:  null title included, as in Markdown.pl
    (Note contents)
      | writerIgnoreNotes opts -> return mempty
      | otherwise              -> do
                        st <- get
                        let notes = stNotes st
                        let number = (length notes) + 1
                        let ref = show number
                        htmlContents <- blockListToNote opts ref contents
                        -- push contents onto front of notes
                        put $ st {stNotes = (htmlContents:notes)}
                        let revealSlash = ['/' | writerSlideVariant opts
                                                 == RevealJsSlides]
                        let link = H.a ! A.href (toValue $ "#" ++
                                         revealSlash ++
                                         writerIdentifierPrefix opts ++ "fn" ++ ref)
                                       ! A.class_ "footnoteRef"
                                       ! prefixedId opts ("fnref" ++ ref)
                                       $ H.sup
                                       $ toHtml ref
                        return $ case writerEpubVersion opts of
                                      Just EPUB3 -> link ! customAttribute "epub:type" "noteref"
                                      _          -> link
    (Cite cits il)-> do contents <- inlineListToHtml opts il
                        let citationIds = unwords $ map citationId cits
                        let citeClass = if writerScholarly opts
                                           then "scholmd-citation"
                                           else "citation"
                        let result = H.span ! A.class_ citeClass $ contents
                        return $ if writerHtml5 opts
                                    then result ! customAttribute "data-cites" (toValue citationIds)
                                    else result
    (NumRef numref _raw) -> do st <- get
                               let toMath lab = mathToMathJax opts InlineMath lab
                               let refId = numRefId numref
                               let refLinkClass = "scholmd-crossref"
                               let refText = case numRefStyle numref of
                                               PlainNumRef -> numRefLabel numref
                                               ParenthesesNumRef -> [Str "("] ++
                                                          numRefLabel numref ++ [Str ")"]
                               refTextHtml <- inlineListToHtml opts refText
                               let isMathId = refId `elem` (stMathIds st)
                               let link = if isMathId
                                             then case numRefStyle numref of
                                                    PlainNumRef -> toMath $ "\\ref{" ++ refId ++ "}"
                                                    ParenthesesNumRef -> toMath $ "\\eqref{" ++ refId ++ "}"
                                             else H.a ! A.href (toValue $ '#' : refId) $ refTextHtml
                               return $ H.span ! A.class_ refLinkClass $ link

blockListToNote :: WriterOptions -> String -> [Block] -> State WriterState Html
blockListToNote opts ref blocks =
  -- If last block is Para or Plain, include the backlink at the end of
  -- that block. Otherwise, insert a new Plain block with the backlink.
  let backlink = [Link [Str "↩"] ("#" ++ writerIdentifierPrefix opts ++ "fnref" ++ ref,[])]
      blocks'  = if null blocks
                    then []
                    else let lastBlock   = last blocks
                             otherBlocks = init blocks
                         in  case lastBlock of
                                  (Para lst)  -> otherBlocks ++
                                                 [Para (lst ++ backlink)]
                                  (Plain lst) -> otherBlocks ++
                                                 [Plain (lst ++ backlink)]
                                  _           -> otherBlocks ++ [lastBlock,
                                                 Plain backlink]
  in  do contents <- blockListToHtml opts blocks'
         let noteItem = H.li ! (prefixedId opts ("fn" ++ ref)) $ contents
         let noteItem' = case writerEpubVersion opts of
                              Just EPUB3 -> noteItem ! customAttribute "epub:type" "footnote"
                              _          -> noteItem
         return $ nl opts >> noteItem'

-- Javascript snippet to render all KaTeX elements
renderKaTeX :: String
renderKaTeX = unlines [
    "window.onload = function(){var mathElements = document.getElementsByClassName(\"math\");"
  , "for (var i=0; i < mathElements.length; i++)"
  , "{"
  , " var texText = mathElements[i].firstChild"
  , " katex.render(texText.data, mathElements[i])"
  , "}}"
  ]

mathToMathJax :: WriterOptions -> MathType -> String -> Html
mathToMathJax opts mathType mathCode =
  case mathType of
    InlineMath -> H.span ! A.class_ "math scholmd-math-inline" $ toHtml $ "\\(" ++ mathCode ++ "\\)"
    DisplayMath attr ->
         mconcat [nl opts,
                  H.span ! A.class_ "math scholmd-math-display"
                         ! A.style "display: block;" $
                     mconcat [toHtml ("\\[" :: String), nl opts,
                              toHtml $ dispMathToLaTeX attr mathCode,
                              nl opts, toHtml ("\\]" :: String)],
                   nl opts]

---
--- Scholarly Markdown floats
---

scholmdFloat :: WriterOptions -> String -> String -> Html -> Html
             -> State WriterState Html
scholmdFloat opts cls identifier content capt = do
  let content' = H.div ! A.class_ "scholmd-float-content" $ content
  return $ H5.figure ! A.class_ (toValue ("scholmd-float " ++ cls))
                     !? (identifier /= "", prefixedId opts identifier)
             $ mconcat [nl opts, content', capt, nl opts]

scholmdFloatCaption :: WriterOptions -> String -> String -> Maybe String -> [Inline]
                    -> State WriterState Html
scholmdFloatCaption opts cls prefix label captext = do
  prefixHtml <- liftM (H.span ! A.class_ "scholmd-caption-head-prefix")
                  $ inlineToHtml opts $ Str prefix
  labelHtml <- case label of
                 Nothing -> return mempty
                 Just lab -> liftM (H.span ! A.class_ "scholmd-caption-head-label")
                               $ inlineToHtml opts $ Str lab
  let headerHtml = case label of
                   Just _ -> H.span ! A.class_ "scholmd-caption-head"
                               $ mconcat [prefixHtml, labelHtml]
                   Nothing -> mempty
  textHtml <- if (null captext)
                 then return mempty
                 else liftM (H.span ! A.class_ "scholmd-caption-text")
                        $ inlineListToHtml opts captext
  return $ if (isNothing label) && (null captext)
              then mempty
              else mconcat [ nl opts,
                             H.div ! A.class_ (toValue cls) $ H5.figcaption
                             $ mconcat [headerHtml, textHtml] ]

-- | main caption for floats
scholmdFloatMainCaption :: WriterOptions -> String -> Maybe String -> [Inline]
                        -> State WriterState Html
scholmdFloatMainCaption opts = scholmdFloatCaption opts "scholmd-float-caption"

-- | caption for subfigures
scholmdFloatSubfigCaption :: WriterOptions -> Maybe String -> [Inline]
                          -> State WriterState Html
scholmdFloatSubfigCaption opts = scholmdFloatCaption opts "scholmd-float-subcaption" ""

-- | Main helper function for constructing a float with caption from a rendered content block
scholmdFloatFromAttr :: WriterOptions -> String -> String -> Attr -> [Inline] -> Html
                     -> State WriterState Html
scholmdFloatFromAttr opts className captionPrefix attr caption content = do
  let ident = getIdentifier attr
  let numLabel = lookupKey "numLabel" attr
  let className' = if (hasClass "wide" attr)
                      then className ++ " scholmd-widefloat"
                      else className
  floatCaption <- scholmdFloatMainCaption opts captionPrefix numLabel caption
  scholmdFloat opts className' ident content floatCaption

figureToHtml :: FigureType -> WriterOptions -> Attr -> [Block] -> PreparedContent -> [Inline]
             -> State WriterState Html
figureToHtml ImageFigure = imageGridToHtml
figureToHtml TableFigure = tableFloatToHtml
figureToHtml LineBlockFigure = algorithmToHtml
figureToHtml ListingFigure = codeFloatToHtml

imageGridToHtml :: WriterOptions -> Attr -> [Block] -> PreparedContent -> [Inline]
                -> State WriterState Html
imageGridToHtml opts attr imageGrid _fallback caption = do
  -- check for single-image float figure, strip the subcaption if this is the case
  let subfigRows = case (head imageGrid) of
                      -- get rid of any subcaption for single image
                      ImageGrid [[Image a _ c]] -> [[Image a [] c]]
                      ImageGrid a -> a
                      _ -> [[]] -- should never happen
  let subfigIds = case (safeRead $ fromMaybe [] $ lookupKey "subfigIds" attr) :: Maybe [String] of
                      Just a -> a
                      Nothing -> [""]
  -- determine whether to show subfig enumeration labels (a), (b), etc
  let appendLabel = any (not . null) subfigIds && not (hasClass "nonumber" attr)
  let subfiglist = intercalate [LineBreak] subfigRows
  -- need to expand the "same" or "^" keyword for width
  subfiglist' <- mapM (setImageWidthFromHistory) subfiglist
  -- Enumerate all the subfigures
  let subfigs = evalState (mapM (subfigsToHtml opts appendLabel) subfiglist') 1
  subfigsHtml <- sequence subfigs -- Render all subfigs
  let figure = mconcat subfigsHtml
  scholmdFloatFromAttr opts "scholmd-figure" "Figure" attr caption figure

-- Transforms a (single-image) subfigure to HTML.
-- The State Int monad implements the counter for automatic subfigure enumeration
subfigsToHtml :: WriterOptions -> Bool -> Inline -> State Int (State WriterState Html)
subfigsToHtml opts _ LineBreak = do
  return $ return $ if writerHtml5 opts then H5.br else H.br
subfigsToHtml opts appendLabel (Image attr txt (s,tit)) = do
  currentIndex <- get
  put (currentIndex + 1)
  let ident = getIdentifier attr
  let size = case lookupKey "width" attr of
                  Just width -> "width: " ++ width
                  Nothing -> ""
  let sublabel = if appendLabel
                    then Just $ "(" ++ (alphEnum currentIndex) ++ ")"
                    else Nothing
  let subcap = scholmdFloatSubfigCaption opts sublabel txt
  let img = H5.img ! (A.src $ toValue s) !? (tit /="", A.title $ toValue tit)
  let content = liftM (\sc -> mconcat[nl opts, img, sc, nl opts]) subcap
  let subfigContext = H5.figure ! A.class_ "scholmd-subfig"
                        !? (ident /= "", prefixedId opts ident)
                        ! A.style (toValue ("display: inline-block; " ++ size :: String))
  return $ liftM subfigContext content
subfigsToHtml _ _ _ = return $ return mempty

algorithmToHtml :: WriterOptions -> Attr -> [Block] -> PreparedContent -> [Inline]
                -> State WriterState Html
algorithmToHtml opts attr alg _fallback caption = do
  algorithm <- blockListToHtml opts alg
  scholmdFloatFromAttr opts "scholmd-algorithm" "Algorithm" attr caption algorithm

tableFloatToHtml :: WriterOptions -> Attr -> [Block] -> PreparedContent -> [Inline]
                 -> State WriterState Html
tableFloatToHtml opts attr tabl _fallback caption = do
  table <- blockListToHtml opts tabl
  scholmdFloatFromAttr opts "scholmd-table-float" "Table" attr caption table

codeFloatToHtml :: WriterOptions -> Attr -> [Block] -> PreparedContent -> [Inline]
                 -> State WriterState Html
codeFloatToHtml opts attr codeblk _fallback caption = do
  codeblock <- blockListToHtml opts codeblk
  scholmdFloatFromAttr opts "scholmd-listing-float" "Listing" attr caption codeblock
