module Main where

import Data.List
import Data.Maybe
import System.Environment
import Text.Printf

import NanoML

main = do
  [dir] <- getArgs
  results <- checkAllFrom dir
  printf "\nDONE!\n"
  let (ss, fs) = partition (isSuccess . snd) . map fromJust . filter isJust $ results
  let becauseOf r = (r `isInfixOf`) . show . counterExample . snd
  printf "%d programs:\n" (length ss + length fs)
  printf "  %d did not fail at runtime\n" (length ss)
  printf "  %d timed out\n" (length (filter (becauseOf "timeout") fs))
  printf "  %d did failed at runtime:\n"
    (length fs - length (filter (becauseOf "timeout") fs))
  printf "    %d due to an unbound variable or datacon\n"
    (length (filter (becauseOf "Unbound") fs) +
     length (filter (becauseOf "unknown") fs))
  printf "    %d due to an output-type-mismatch"
    (length (filter (becauseOf "OutputType") fs))
  printf "    %d due to a type error (%02.02f %%)"
    (length (filter (becauseOf "TypeError") fs))
    ((fromIntegral (length (filter (becauseOf "TypeError") fs))
      / fromIntegral (length ss + length fs) :: Double)
     * 100)