if $addon == "" then
  del(.gapps_dir) | .data_dir = $vanilla
else
  .gapps_dir = $addon | .data_dir = $google
end
