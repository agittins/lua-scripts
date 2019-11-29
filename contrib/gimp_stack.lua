--[[

    gimp_stack.lua - export multiple images and open as layers in gimp

    Copyright (C) 2016 Bill Ferguson <wpferguson@gmail.com>.

    Portions are lifted from hugin.lua and thus are 

    Copyright (c) 2014  Wolfgang Goetz
    Copyright (c) 2015  Christian Kanzian
    Copyright (c) 2015  Tobias Jakobs


    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]
--[[
    gimp_stack - export multiple images and open as layers with gimp for editing

    This script provides another storage (export target) for darktable.  Selected
    images are exported in the specified format to temporary storage.  The images are 
    combined into a single file. Gimp is launched and opens the merged file.  A dialog 
    prompts to import the image as layers. After editing, the image is imported back into
    the current collection, using the path of the first image selected, as stack.tif.  
    The image is then imported into the database.  The exported files that made up the 
    stacked image are deleted from temporary storage to avoid cluttering up the system. 
    

    ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
    * gimp - http://www.gimp.org
    * imagemagick - http://www.imagemagick.org

    USAGE
    * require this script from your main lua file
    * select an images to stack and edit with gimp
    * in the export dialog select "Edit as layers with gimp" and select the format and bit depth for the
      exported image
    * Press "export"
    * Import the image as layers when gimp starts
    * Edit the image with gimp then save the changes with File->Overwrite....
    * Exit gimp
    * The edited image will be imported and grouped with the original collection

    CAVEATS
    * Developed and tested on Ubuntu 14.04 LTS with darktable 2.0.3 and gimp 2.9.3 (development version with
      > 8 bit color)
    * There is no provision for dealing with the xcf files generated by gimp, since darktable doesn't deal with 
      them.  You may want to save the xcf file if you intend on doing further edits to the image or need to save 
      the layers used.  Where you save them is up to you.

    BUGS, COMMENTS, SUGGESTIONS
    * Send to Bill Ferguson, wpferguson@gmail.com
]]

local dt = require "darktable"
local dtutils = require "lib/dtutils"
local gettext = dt.gettext
require "official/yield"

-- FIXME: do we really need this? dt.configuration.check_version(...,{3,0,0})

-- Tell gettext where to find the .mo file translating messages for a particular domain
gettext.bindtextdomain("gimp_stack",dt.configuration.config_dir.."/lua/")

-- Thanks to http://lua-users.org/wiki/SplitJoin for the split and split_path functions
local function _(msgid)
    return gettext.dgettext("gimp_stack", msgid)
end

local function show_status(storage, image, format, filename,
  number, total, high_quality, extra_data)
  dt.print(string.format(_("Exporting to gimp %i/%i"), number, total))
end

-- ==== from image_stack ======
-- copy an images database attributes to another image.  This only
-- copies what the database knows, not the actual exif data in the 
-- image itself.

local function copy_image_attributes(from, to, ...)
  local args = {...}
  if #args == 0 then
    args[1] = "all"
  end
  if args[1] == "all" then
    args[1] = "rating"
    args[2] = "colors"
    args[3] = "exif"
    args[4] = "meta"
    args[5] = "GPS"
  end
  for _,arg in ipairs(args) do
    if arg == "rating" then
      to.rating = from.rating
    elseif arg == "colors" then
      to.red = from.red
      to.blue = from.blue
      to.green = from.green
      to.yellow = from.yellow
      to.purple = from.purple
    elseif arg == "exif" then
      to.exif_maker = from.exif_maker
      to.exif_model = from.exif_model
      to.exif_lens = from.exif_lens
      to.exif_aperture = from.exif_aperture
      to.exif_exposure = from.exif_exposure
      to.exif_focal_length = from.exif_focal_length
      to.exif_iso = from.exif_iso
      to.exif_datetime_taken = from.exif_datetime_taken
      to.exif_focus_distance = from.exif_focus_distance
      to.exif_crop = from.exif_crop
    elseif arg == "GPS" then
      to.elevation = from.elevation
      to.longitude = from.longitude
      to.latitude = from.latitude
    elseif arg == "meta" then
      to.publisher = from.publisher
      to.title = from.title
      to.creator = from.creator
      to.rights = from.rights
      to.description = from.description
    else
      dt.print_error(_("Unrecognized option to copy_image_attributes: " .. arg))
    end
  end
end

-- == end of copy_image_attributes from image_stack.lua

local function gimp_stack_edit(storage, image_table, extra_data) --finalize
  --if not dtutils.check_if_bin_exists("gimp") then
  --  dt.print_error(_("gimp not found"))
  --  return
  --end

  --if not dtutils.check_if_bin_exists("convert") then
  --  dt.print_error(_("convert not found"))
  --  return
  --end

  -- list of exported images 
  local img_list
  local align_list

   -- reset and create image list
  img_list = ""
  align_list = ""

  for _,exp_img in pairs(image_table) do
    -- exp_img = '/tmp/IMG_9519.tif'
    img_list = img_list ..exp_img.. " "
  end
  dt.print_error(img_list)


  -- Instead of working on a stacked tiff in tmp, we put in
  -- with the source images so that gimp can also easily save
  -- an xcf (ignored by dt) in the same directory without having
  -- to hunt around for the right folder.
  --
  -- local tmp_stack_image = dt.configuration.tmp_dir.."/stack.tif"

  -- FIXME: low-priority. Should check for existing destination file, and make a sensible
  -- choice rather than blindly over-writing like this.
  local stack_image = dt.gui.action_images[1].path .. "/" .. dt.gui.action_images[1].filename ..".gimp_stack.tif"
  -- FIXME: low-priority, but we should be careful to get an actual temp name for
  -- the prefix to avoid clobbering or including ones we didn't expect to be there.
  local align_prefix = dt.configuration.tmp_dir.."/"..dt.gui.action_images[1].filename ..".aligned-"

  dt.print(_("Aligning images..."))

  os.execute("align_image_stack -a " .. align_prefix .. " -m -d -i --distortion --gpu "..img_list)


  dt.print(_("Stacking images into "..align_prefix.."* ..."))

  

  os.execute("convert "..align_prefix.."*  "..stack_image)
  os.execute("rm "..img_list)
  os.execute("rm "..align_prefix.."*")

  dt.print(_("Launching gimp..."))

  local gimpStartCommand
  gimpStartCommand = "gimp "..stack_image
  
  dt.print_error(gimpStartCommand)

  -- coroutine.yield("RUN_COMMAND", gimpStartCommand)
  -- AJG - probably need to use dtsys.external_command() or something here, I am guessing.
  os.execute(gimpStartCommand)

  -- AJG seems sensible to wait until after we finish editing before importing. Probably
  -- OK either way, but we might avoid some thumbnail / metadata weirdnesses.

  dt.print(_("Importing image and copying tags..."))
  local imported_image = dt.database.import(stack_image)
  local created_tag = dt.tags.create(_("Created with|gimp_stack|sources ".. img_list ..""))
  dt.tags.attach(created_tag, imported_image)
  -- all the images are the same except for time, so just copy the  attributes
  -- from the first
  for img,_ in pairs(image_table) do
    copy_image_attributes(img, imported_image)
    break
  end


  
end

-- Register
dt.register_storage("module_gimp_stack", _("Edit as layers with gimp"), show_status, gimp_stack_edit)

--


