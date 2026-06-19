output "vm_app_private_ip" {
  value = aws_instance.app.private_ip
}

output "vm_db_private_ip" {
  value = aws_instance.db.private_ip
}

output "vm_win_private_ip" {
  value = aws_instance.win.private_ip
}

output "vpc_id" {
  value = aws_vpc.lab.id
}

output "ec2_instance_connect_endpoint_id" {
  value = aws_ec2_instance_connect_endpoint.lab.id
}

output "s3_bucket_name" {
  value = aws_s3_bucket.lab.bucket
}
