{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}

module UI
  ( UI.initialize
  , uploadLightMaps
  , uploadBSP
  ) where

import Data.Foldable (for_)
import Data.Traversable (for)
import qualified Data.Vector as BoxedV
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Storable as V (unsafeWith)
import Foreign
import Foreign (Ptr, nullPtr)
import Foreign.C (peekCString)
import GLObjects
import Graphics.GL
import Linear
import Parser
import Reactive.Banana.Frameworks
import SDL
import Text.Printf

initialize :: IO Window
initialize = do
  SDL.initialize [InitVideo]
  window <-
    createWindow
      "Quake 3 BSP Viewer"
      defaultWindow
      {windowOpenGL = Just defaultOpenGL {glProfile = Compatibility Debug 4 0}}
  glCreateContext window >>= glMakeCurrent window
  glEnable GL_FRAMEBUFFER_SRGB
  glEnable GL_BLEND
  glFrontFace GL_CW
  _ <- setMouseLocationMode RelativeLocation
  installDebugHook
  glEnable GL_DEPTH_TEST
  return window

data VertexAttribFormat = VertexAttribFormat
  { vafAttribute :: Attribute
  , vafComponents :: GLsizei
  , vafType :: GLenum
  , vafOffset ::GLuint
  }

configureVertexArrayAttributes
  :: MonadIO m
  => GLuint -> [VertexAttribFormat] -> m ()
configureVertexArrayAttributes vao formats =
  for_ formats $ \VertexAttribFormat {..} -> do
    glEnableVertexArrayAttrib vao (attribIndex vafAttribute)
    glVertexArrayAttribBinding vao (attribIndex vafAttribute) 0
    glVertexArrayAttribFormat
      vao
      (attribIndex vafAttribute)
      vafComponents
      vafType
      (fromIntegral GL_FALSE)
      vafOffset

uploadBSP :: BSPFile -> IO VertexArrayObject
uploadBSP BSPFile {..} = do
  vbo <-
    V.unsafeWith bspVertexes $ \vData -> do
      vbo <- create glCreateBuffers
      glNamedBufferData
        vbo
        (fromIntegral (V.length bspVertexes * sizeOf (V.head bspVertexes)))
        vData
        GL_STATIC_DRAW
      return vbo
  vao <- create glCreateVertexArrays
  glVertexArrayVertexBuffer
    vao
    0
    vbo
    0
    (fromIntegral (sizeOf (undefined :: Parser.Vertex)))
  configureVertexArrayAttributes
    vao
    [ VertexAttribFormat
      { vafAttribute = Position
      , vafComponents = 3
      , vafType = GL_FLOAT
      , vafOffset = 0
      }
    , VertexAttribFormat
      { vafAttribute = UV 0
      , vafComponents = 2
      , vafType = GL_FLOAT
      , vafOffset = fromIntegral (sizeOf (undefined :: V3 Float))
      }
    , VertexAttribFormat
      { vafAttribute = UV 1
      , vafComponents = 2
      , vafType = GL_FLOAT
      , vafOffset =
          fromIntegral
            (sizeOf (undefined :: V3 Float) + sizeOf (undefined :: V2 Float))
      }
    , VertexAttribFormat
      { vafAttribute = GLObjects.Normal
      , vafComponents = 3
      , vafType = GL_FLOAT
      , vafOffset =
          fromIntegral
            (sizeOf (undefined :: V3 Float) + sizeOf (undefined :: V2 Float) +
             sizeOf (undefined :: V2 Float))
      }
    ]
  ebo <- create glCreateBuffers
  V.unsafeWith bspMeshVerts $ \eboData ->
    glNamedBufferData
      ebo
      (fromIntegral (V.length bspMeshVerts * sizeOf (0 :: GLuint)))
      eboData
      GL_STATIC_DRAW
  glVertexArrayElementBuffer vao ebo
  return (VertexArrayObject vao)

uploadLightMaps :: BSPFile -> IO [GLObjects.Texture]
uploadLightMaps BSPFile {bspLightMaps} =
  for
    (V.toList bspLightMaps)
    (\(LightMap pixels) ->
       uploadTexture2D $
       V.convert $
       V.concatMap id $
       V.generate (128 * 128) $ \j ->
         let overbright = 2
             colours =
               [ shiftL
                 (fromIntegral (pixels V.! (j * 3 + n)) :: Int)
                 overbright
               | n <- [0 .. 2]
               ]
         in BoxedV.fromList $ fmap fromIntegral $
            if any (> 255) colours
              then let maxi = maximum colours
                   in fmap (\a -> a * 255 `div` maxi) colours
              else colours)

-- | This will install a synchronous debugging hook to allow OpenGL to notify us
-- if we're doing anything deprecated, non-portable, undefined, etc.
installDebugHook :: IO ()
installDebugHook
  | gl_ARB_debug_output = do
    cb <- makeGLDEBUGPROC glCallback
    glDebugMessageCallbackARB cb nullPtr
    glEnable GL_DEBUG_OUTPUT_SYNCHRONOUS_ARB
  | otherwise = return ()

glCallback :: GLenum
           -> GLenum
           -> GLuint
           -> GLenum
           -> GLsizei
           -> Ptr GLchar
           -> Ptr ()
           -> IO ()
glCallback source t ident severity _ message _ = do
  message' <- peekCString message
  putStrLn $
    printf
      "opengl %s [%s] %s (%s): %s"
      t'
      severity'
      source'
      (show ident)
      message'
  where
    source' :: String
    source' =
      case source of
        GL_DEBUG_SOURCE_API_ARB -> "API"
        GL_DEBUG_SOURCE_WINDOW_SYSTEM_ARB -> "Window System"
        GL_DEBUG_SOURCE_SHADER_COMPILER_ARB -> "Shader Compiler"
        GL_DEBUG_SOURCE_THIRD_PARTY_ARB -> "Third Party"
        GL_DEBUG_SOURCE_APPLICATION_ARB -> "Application"
        GL_DEBUG_SOURCE_OTHER_ARB -> "Other"
        _ -> "Unknown"
    t' :: String
    t' =
      case t of
        GL_DEBUG_TYPE_ERROR_ARB -> "Error"
        GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR_ARB -> "Deprecated Behaviour"
        GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR_ARB -> "Undefined Behaviour"
        GL_DEBUG_TYPE_PORTABILITY_ARB -> "Portability"
        GL_DEBUG_TYPE_PERFORMANCE_ARB -> "Performance"
        GL_DEBUG_TYPE_OTHER_ARB -> "Other"
        _ -> "Unknown"
    severity' :: String
    severity' =
      case severity of
        GL_DEBUG_SEVERITY_HIGH_ARB -> "High"
        GL_DEBUG_SEVERITY_MEDIUM_ARB -> "Medium"
        GL_DEBUG_SEVERITY_LOW_ARB -> "Low"
        _ -> "Unknown"
