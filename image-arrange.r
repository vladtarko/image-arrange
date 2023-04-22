#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly=TRUE)

# arguments:
# args[1] path of the folder with images
# if missing current folder is used

# libraries and themes -----------------------------------------------

library(tidyverse)
library(shiny)
library(shinythemes)
library(reactable)
library(htmltools)
library(glue)
library(magick)
library(exiftoolr)  # needs to run `install_exiftool()` after first install

# reactable theme that matches the color of the shiny theme
options(reactable.theme = reactableTheme(
  color = "hsl(209, 9%, 87%)",
  backgroundColor = "#2b3e50",
  borderColor = "#2b3e50",
  highlightColor = "#436e91",
  rowSelectedStyle = list(backgroundColor = "#428bca")
))

# load images --------------------------------------------------------

# if no arguments are given, use current directory
if (!exists("arg")) {
  path = paste0(getwd(), "/")
} else {
  if (str_ends(args[1], "/")) {
    path = args[1]
  } else {
    path = paste0(args[1], "/")
  }
}

img_ext <- ".jpg|.jpeg|.png|.gif|.tiff|.svg"
files   <- list.files(path, pattern = img_ext)
n_files <- length(files)

# load images
cat("Loading images...")
images <- paste0(path, files) |> map(\(f){ 
  
    tryCatch(
      image <- image_read(f),
      
      error=function(e) {
        message('Check the memory allocation policy of ImageMagick set in `/etc/ImageMagick-6/policy.xml`.')
        print(e)
      }
    )
    
    # keep only one frame from gifs
    if (str_detect(f, ".gif")){
      # how many frames
      n_frames <- length(image)
      # pick random frame from gif
      image <- image[runif(1, min = 1, max = n_frames)]
    }
    
    return(image)
  }, .progress = TRUE)

# create thumbnails 
thumbnails <- images |> map(\(image){ image_scale(image, "100") }, .progress = TRUE)

# write thumbnails to temp directory
temp_dir <- paste0(tempdir(), "/")
iwalk(thumbnails, \(image, i) {
  image_write(image, path = paste0(temp_dir, files[i]))
}, .progress = TRUE)

# create dataset of files to be displayed in the table --------------
df <- tibble(File = files) |> 
  rownames_to_column("Original Order") |> 
  mutate(
    `Original Order` = as.numeric(`Original Order`),
    Prefix = `Original Order`,
    Skip = FALSE
  )

# ui ---------------------------------------------------------------
ui <- fluidPage(
  theme = shinytheme("superhero"),
  ## left side --------------
  column(5,
    # scrollable div (vertical scroll only)
    div(style = "overflow-y: scroll; height:850px;",
        reactableOutput("table")
    )
  ),
  ## right side -------------------
  column(7,
    fluidRow(
      p(),
      paste("Current folder:", path),
      p(),
      div(style="display:inline-block; padding-right: 10px;",
        actionButton("rename_btn", "Rename all files adding prefix")
      ),
      div(style="display:inline-block",
        textInput("file_name_txt", 
                  label = "Custom name to replace file names (leave empty to keep existing file names):", 
                  value = "", width = 250)
      )
      #actionButton("slideshow_btn", "Create slideshow (mp4)")
    ),
    fluidRow(
      sliderInput(inputId = "zoom",
                  label = "Zoom:",
                  min = 50,
                  max = 300,
                  value = 100)
    ),
    fluidRow(
      div(style="display:inline-block", 
          actionButton("move_up_btn", "Move up"),
          actionButton("move_dn_btn", "Move down")
          ),
      div(style="display:inline-block; padding: 0px 60px 0px 10px;", 
          numericInput("step", 
                     label = "Steps:", 
                     value = 1, 
                     min = 1, 
                     max = n_files - 1,
                     width = 100),
      ),
      div(style="display:inline-block", 
          actionButton("skip_btn", "Skip image")
      )
    ),
    #p(),
    div(style = "overflow-y: scroll; height:500px;",
        uiOutput("show_picture")
    )
  )
)

# server side -------------------------------------------------------------------
server <- function(input, output, session) {
  
  # format the main table with images
  updateThumbnails <- function(df, selected) {
    df |> 
      reactable(
        columns = list(
          # show thumbnails from the temp dir
          File = colDef(cell = function(value) {
            file_path <- paste0(temp_dir, value)
            img_src <- knitr::image_uri(file_path)
            image <- img(src = img_src, style = "height: 100%", alt = value)
            tagList(
              div(style = glue("height: {input$zoom}px; display: block;"), image)
            )
          },
          width = 450),
          
          `Original Order` = colDef(align = "center", width = 75),
          
          Prefix = colDef(align = "center", width = 75,
                          cell = function(value, index){
                            skipped <- ifelse(df$Skip[index], "(skip)", "")
                            div(paste(value, skipped))
                          }),
          
          Skip = colDef(show = FALSE)
        ),
        defaultPageSize = n_files,
        showPageSizeOptions = FALSE,
        showPagination = FALSE,
        selection = "single",
        onClick = "select",
        highlight = TRUE,
        defaultSelected = selected,
        borderless = TRUE,
        compact = TRUE
      ) |> 
      renderReactable() -> output$table
  }
  
  # show main table at first run
  updateThumbnails(df, selected = 1)
  
  
  # show selected file as big image ------------------------
  output$show_picture <- renderUI({
    selected <- getReactableState("table", "selected")
    req(selected)
    file_path <- paste0(path, df[[selected, 2]])
    
    tagList(
       img(src = knitr::image_uri(file_path), width = "600px"),
       p(),
       print("File name: "),
       print(df[[selected, 2]]),
       p(),
       print("File size: "),
       scales::number_bytes(file.info(file_path)$size, units = "binary"),
       print(", Image size: "),
       paste(exif_read(file_path)$ImageWidth, "x", exif_read(file_path)$ImageHeight),
       print(", Megapixels: "),
       print(exif_read(file_path)$Megapixels),
       p()
    )
  })
  
  
  # move up picture -----------------------------------------
  observeEvent(input$move_up_btn, {
    selected <- getReactableState("table", "selected")
    req(selected)
    
    if (selected - input$step < 1) return()
    
    # move selected image
    df[[selected, 3]] <<- df[[selected, 3]] - input$step
    
    # move all the images above the selected one step down
    for (s in seq(1, input$step)){
      df[[selected - s, 3]] <<- df[[selected - s, 3]] + 1
    }
    
    df <<- df |> arrange(Prefix)
    
    updateThumbnails(df, selected = selected - input$step)
    
  })
  
  
  # mode down picture ---------------------------------------
  observeEvent(input$move_dn_btn, {
    selected <- getReactableState("table", "selected")
    req(selected)
    
    if (selected + input$step > n_files) return()
    
    # move selected
    df[[selected, 3]] <<- df[[selected, 3]] + input$step
    
    # move all the images below the selected one step up
    for (s in seq(1, input$step)){
      df[[selected + s, 3]] <<- df[[selected + s, 3]] - 1
    }
    
    df <<- df |> arrange(Prefix)
    
    updateThumbnails(df, selected = selected + input$step)
    
  })
  
  
  # skip image --------------------------------------------
  observeEvent(input$skip_btn, {
    selected <- getReactableState("table", "selected")
    req(selected)
    
    df[[selected, 4]] <<- ifelse(df[[selected, 4]], FALSE, TRUE)
    
    updateThumbnails(df, selected = selected)
  })
  
  
  # rename all -------------------------------------------
  observeEvent(input$rename_btn, {
    
    df_ <- df |> mutate(
      PadPrefix = str_pad(Prefix, 
                          width = str_length(as.character(n_files)),
                          pad = "0"),
      Prefix = ifelse(Skip, paste0("skip_", PadPrefix), PadPrefix)
      )
    
    if (input$file_name_txt == "") {
      df_ <- df_ |> mutate(new_file_name = paste(Prefix, File, sep = "_"))
    } else {
      df_ <- df_ |> 
        mutate(
          extension = str_extract(File, "\\.[^.\\\\/:*?\"<>|\\r\\n]+$"),
          new_file_name = paste0(Prefix, "_", input$file_name_txt, extension)
        )
    }
    
    file.rename(
      from = paste0(path, df_$File),
      to   = paste0(path, df_$new_file_name)
      )
    
    showNotification("Renamining done!")
    
    files <<- df_ |> pull(new_file_name)
    df <<- df |> mutate(File = files)
    
  })
  
  # # create slideshow ------------------------------------------------
  # observeEvent(input$slideshow_btn, {
  #  # av::av_encode_video(images, output = "slideshow.mp4")
  #   
  #   frames <- df |> filter(!Skip) |> pull(File)
  # 
  #   av::av_encode_video(frames, framerate = 1,
  #                      output = "slideshow.mp4")
  # })
  
  # close app when browser window is closed ------------------------
  session$onSessionEnded(function() {
    stopApp()
  })
}

# run app in the browser
shinyApp(ui, server, options = list(launch.browser = TRUE))

