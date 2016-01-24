# Parsing tables from image based PDFs with open source tools

```
$ brew install poppler
$ brew install tesseract --HEAD
$ brew install imagemagick --with-fftw
$ brew install gocr --with-lib --with-netpbm
```

To run

```
$ pdfimages -png aviva_plc_annual_return_2014.pdf /tmp/out
$ cp /tmp/out-037.png .
$ ruby ocr.rb out-037.png
```
