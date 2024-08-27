resource "tls_private_key" "example" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "${var.env_prefix}-generated_key"
  public_key = tls_private_key.example.public_key_openssh
}

resource "aws_network_interface" "private_nic" {
  count          = var.vm_count
  subnet_id      = aws_subnet.private.id
  private_ips    = ["10.0.2.${count.index + 100}"]
  security_groups = [aws_security_group.allow_ssh.id]
  tags = {
    Name = "${var.env_prefix}-private-nic-${count.index}"
  }
}

resource "null_resource" "pem_file" {
  provisioner "local-exec" {
    command = <<EOT
      rm -f ${var.env_prefix}_generated_key.pem
      echo '${tls_private_key.example.private_key_pem}' > ${var.env_prefix}_generated_key.pem
      chmod 400 ${var.env_prefix}_generated_key.pem
    EOT
  }
}

resource "aws_instance" "linux_instance" {
  count                 = var.vm_count
  ami                   = var.ami
  instance_type         = var.instance_type
  key_name              = aws_key_pair.generated_key.key_name
  subnet_id             = aws_subnet.public.id
  associate_public_ip_address = true

  # Associate the instance with the IAM role via the instance profile using its name
  iam_instance_profile = aws_iam_instance_profile.ec2_ecr_instance_profile.name

  root_block_device {
    volume_size = var.root_disk_size
    volume_type = "gp2" # General Purpose SSD
  }

  vpc_security_group_ids = [aws_security_group.allow_ssh.id]

  tags = {
    Name = "${var.env_prefix}-instance-${count.index}"
  }

  user_data = <<-EOF
              #!/bin/bash
              # Update the package index
              sudo dnf update -y

              # Install Docker
              sudo dnf install -y docker git

              # Increase number of open files per container
              sudo sed -i.bak -e 's|32768:65536|524288:524288|g' /etc/sysconfig/docker

              # Start the Docker service
              sudo systemctl start docker

              # Enable Docker to start on boot
              sudo systemctl enable docker

              # Add ec2-user to the docker group
              sudo usermod -aG docker ec2-user

              EOF

  depends_on = [null_resource.pem_file]
}

resource "aws_network_interface_attachment" "private_nic_attachment" {
  count                = var.vm_count
  instance_id          = aws_instance.linux_instance[count.index].id
  network_interface_id = aws_network_interface.private_nic[count.index].id
  device_index         = 1
}

resource "local_file" "instances_info" {
  content  = jsonencode({
    names = aws_instance.linux_instance[*].tags.Name
    ips   = aws_instance.linux_instance[*].public_ip
  })
  filename = "${path.module}/${var.env_prefix}_instances_info.json"
}
